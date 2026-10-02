# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Zenodo's documented deposition-v1 REST API (not the InvenioRDM records API).
# No remote response body or underlying HTTP exception leaves this file: both
# can contain Authorization headers, request URLs or reflected credentials.

const API_VERSION = "deposition-v1"
const ORIGINS = Dict(:sandbox => "https://sandbox.zenodo.org", :production => "https://zenodo.org")
const HOSTS = Dict(:sandbox => "sandbox.zenodo.org", :production => "zenodo.org")
const TOKEN_VARIABLES = Dict(:sandbox => "ZENODO_SANDBOX_TOKEN", :production => "ZENODO_TOKEN")
const DOI_PREFIXES = Dict(:sandbox => "10.5072/zenodo.", :production => "10.5281/zenodo.")
const USER_AGENT = "ZenodoDeposits.jl/0.1"

"""
    Secret(value)

A credential wrapper that always prints as `[REDACTED]`.
"""
struct Secret
    value::String
end

"""
    show(io, ::Secret)

Print `[REDACTED]`; the value is never shown.
"""
Base.show(io::IO, ::Secret) = print(io, "[REDACTED]")

"""
    _http(method, url, headers, body)

The default transport: one HTTP request with redirects, automatic retries,
status exceptions and HTTP.jl logging all disabled. Retries are handled by
[`_request`](@ref), which knows which requests are safe to repeat.
"""
function _http(method, url, headers, body)
    with_logger(NullLogger()) do
        HTTP.request(method, url, headers, body;
            redirect=false, retry=false, status_exception=false, logerrors=false,
            connect_timeout=10, readtimeout=300)
    end
end

"""
    Client(env=:sandbox; environ=ENV, netrc=..., transport, sleeper, clock, attempts=4, retry_budget=60)

A Zenodo deposition-v1 client for `env` (`:sandbox` or `:production`).

There is deliberately no token argument. The token comes from
`ZENODO_SANDBOX_TOKEN` (sandbox) or `ZENODO_TOKEN` (production) in `environ`,
or else from the `password` of the `sandbox.zenodo.org` / `zenodo.org` entry
in the netrc file (`\$NETRC`, default `~/.netrc`), which must not be group- or
world-readable. The token is held in a [`Secret`](@ref ZenodoDeposits.Secret) and redacted from
`show` and from every error.

`transport(method, url, headers, body)`, `sleeper(seconds)` and `clock()` are
injectable for tests. Rate limits (429) and, for idempotent requests, 5xx and
transport errors are retried up to `attempts` times with exponential backoff
that honours `Retry-After`, never waiting more than `retry_budget` seconds in
total.
"""
struct Client{T,S,C}
    env::Symbol
    token::Secret
    transport::T
    sleeper::S
    clock::C
    attempts::Int
    retry_budget::Int
end

"""
    _default_netrc(environ) -> String

The netrc path: `\$NETRC` if set, else `~/.netrc`.
"""
_default_netrc(environ) = get(environ, "NETRC", joinpath(homedir(), ".netrc"))

function Client(env::Symbol=:sandbox; environ=ENV, netrc::AbstractString=_default_netrc(environ),
                transport=_http, sleeper=sleep, clock=() -> now(UTC), attempts::Int=4, retry_budget::Int=60)
    haskey(ORIGINS, env) || throw(ArgumentError("Zenodo environment must be :sandbox or :production"))
    1 <= attempts <= 6 || throw(ArgumentError("attempts must be between 1 and 6"))
    0 <= retry_budget <= 600 || throw(ArgumentError("retry_budget must be between 0 and 600 seconds"))
    token = _find_token(env, environ, netrc)
    Client(env, Secret(token), transport, sleeper, clock, attempts, retry_budget)
end

"""
    show(io, c::Client)

Print the environment and API version with the token redacted.
"""
Base.show(io::IO, c::Client) = print(io, "ZenodoDeposits.Client(env=:", c.env, ", api=", API_VERSION, ", token=[REDACTED])")

"""
    origin(c) -> String

The fixed HTTPS origin of the client's environment.
"""
origin(c::Client) = ORIGINS[c.env]

"""
    _find_token(env, environ, netrc) -> String

Return the token for `env` from the environment variable, else the netrc
file. Errors name where to put a token and never include any value.
"""
function _find_token(env::Symbol, environ, netrc::AbstractString)
    variable = TOKEN_VARIABLES[env]
    token = strip(string(get(environ, variable, "")))
    if isempty(token)
        token = something(_netrc_password(netrc, HOSTS[env]), "")
    end
    isempty(token) && fail("missing_token",
        "No Zenodo token for $env. Set $variable, or add a `machine $(HOSTS[env]) password ...` entry to your netrc file.")
    occursin(r"^[\x21-\x7e]+$", token) || fail("invalid_token", "The Zenodo token for $env contains whitespace or non-printable characters.")
    return String(token)
end

"""
    _netrc_password(path, host) -> Union{String,Nothing}

The `password` of the `machine host` entry in a netrc file, or `nothing`.
A netrc readable by group or others is refused rather than trusted.
"""
function _netrc_password(path::AbstractString, host::AbstractString)
    isfile(path) || return nothing
    filemode(path) & 0o077 == 0 ||
        fail("unsafe_netrc", "Refusing to read $path: it is readable by other users. Run `chmod 600 $path`.")
    words = split(read(path, String))
    current = nothing
    i = 1
    while i <= length(words)
        word = words[i]
        if word == "machine" && i < length(words)
            current = words[i+1]; i += 2
        elseif word == "default"
            current = nothing; i += 1
        elseif word in ("login", "password", "account") && i < length(words)
            word == "password" && current == host && return String(words[i+1])
            i += 2
        else
            i += 1
        end
    end
    return nothing
end

"""
    checked_id(value) -> String

Return a Zenodo deposition identifier as text, refusing anything that is not
a positive integer (including booleans).
"""
function checked_id(value)
    text = value isa AbstractString || (value isa Integer && !(value isa Bool)) ? string(value) : ""
    occursin(r"^[1-9][0-9]{0,17}$", text) ||
        throw(RemoteError(502, "invalid_zenodo_response", "Zenodo returned an invalid deposition identifier.", false, nothing))
    return text
end

"""
    checked_doi(c, value) -> String

Return `value` if it is a Zenodo DOI for the client's environment
(`10.5072/zenodo.N` in the sandbox, `10.5281/zenodo.N` in production).
"""
function checked_doi(c::Client, value)
    prefix = DOI_PREFIXES[c.env]
    value isa AbstractString && startswith(value, prefix) && occursin(r"^[1-9][0-9]*$", value[length(prefix)+1:end]) ||
        throw(RemoteError(502, "invalid_zenodo_response", "Zenodo returned a DOI for an unexpected service or environment.", false, nothing))
    return String(value)
end

"""
    reserved_doi(c, deposit) -> String

The DOI Zenodo reserved for a draft (`metadata.prereserve_doi.doi`).
"""
function reserved_doi(c::Client, deposit)
    metadata = get(deposit, "metadata", Dict())
    reserved = metadata isa AbstractDict ? get(metadata, "prereserve_doi", Dict()) : Dict()
    checked_doi(c, reserved isa AbstractDict ? get(reserved, "doi", nothing) : nothing)
end

"""
    retry_after_seconds(value, now) -> Union{Int,Nothing}

Parse a `Retry-After` header given as delay-seconds or an IMF-fixdate HTTP
date. Malformed hints return `nothing`; absurdly large numbers saturate.
"""
function retry_after_seconds(value::AbstractString, clock::DateTime=now(UTC))
    text = strip(value)
    seconds = tryparse(Int, text)
    !isnothing(seconds) && return max(0, seconds)
    occursin(r"^[0-9]+$", text) && return typemax(Int)
    endswith(text, " GMT") || return nothing
    try
        date = DateTime(text[1:end-4], dateformat"e, dd u yyyy HH:MM:SS")
        return max(0, ceil(Int, Dates.value(date - clock) / 1000))
    catch
        return nothing
    end
end

"""
    _remote_error(status; ambiguous=false, retry_after=nothing) -> RemoteError

Map an HTTP status to a sanitised [`RemoteError`](@ref) with an actionable
message.
"""
function _remote_error(status::Integer; ambiguous::Bool=false, retry_after=nothing)
    code, message = if status == 401
        ("zenodo_unauthorized", "Zenodo rejected the token. Check that it belongs to this environment and has not expired.")
    elseif status == 403
        ("zenodo_forbidden", "Zenodo refused this operation. Check ownership and the deposit:write / deposit:actions token scopes.")
    elseif status == 404
        ("zenodo_not_found", "The Zenodo deposition was not found. Check the account and environment; no replacement was created.")
    elseif status == 429
        ("zenodo_rate_limited", "Zenodo rate limit reached. Wait, then retry the same operation.")
    elseif status in (400, 409, 413, 415, 422)
        ("zenodo_rejected", "Zenodo rejected the request. Review the draft and its metadata on Zenodo.")
    elseif 300 <= status < 400
        ("zenodo_redirect_refused", "Zenodo redirected a credentialed request. Redirects are refused for token safety.")
    else
        ("zenodo_unavailable", "Zenodo did not return a usable response. Retry the same operation; it reconciles before acting.")
    end
    RemoteError(Int(status), code, message, ambiguous, retry_after)
end

"""
    _request(c, method, url; body_factory, content_type, content_length, expected) -> Dict

Send one API request with bounded retries and return the parsed JSON body.

`GET` and `PUT` are idempotent and are retried on 429, 5xx and transport
errors. `POST` (create, publish) is retried only on 429, which Zenodo returns
before acting; any other failure is raised with `ambiguous=true` so the caller
reconciles instead of repeating it. The delay is `Retry-After` when given,
else `2^(attempt-1)` seconds; if that would exceed the remaining
`retry_budget`, the error is raised with `retry_after` set instead of waiting.
"""
function _request(c::Client, method::String, url::String; body_factory=() -> "",
                  content_type="application/json", content_length=nothing, expected=(200,))
    startswith(url, origin(c) * "/api/") || throw(ArgumentError("Refusing a non-Zenodo endpoint"))
    headers = ["Authorization" => "Bearer " * c.token.value, "Content-Type" => content_type,
               "Accept" => "application/json", "User-Agent" => USER_AGENT]
    isnothing(content_length) || push!(headers, "Content-Length" => string(content_length))
    idempotent = method in ("GET", "PUT")
    waited = 0
    for attempt in 1:c.attempts
        response = nothing
        body = body_factory()
        try
            response = c.transport(method, url, headers, body)
        catch
            (!idempotent || attempt == c.attempts) && throw(_remote_error(503; ambiguous=!idempotent))
        finally
            body isa IO && close(body)
        end
        if !isnothing(response)
            if response.status in expected
                try
                    return JSON3.read(String(response.body), Dict{String,Any})
                catch
                    throw(RemoteError(502, "invalid_zenodo_response",
                        "Zenodo returned malformed JSON. Retry the same operation; it reconciles before acting.", !idempotent, nothing))
                end
            end
            hint = retry_after_seconds(HTTP.header(response, "Retry-After", ""), c.clock())
            retryable = response.status == 429 || (idempotent && response.status in (500, 502, 503, 504))
            if !(retryable && attempt < c.attempts)
                ambiguous = !idempotent && response.status != 429 &&
                            (response.status >= 500 || response.status == 408 || response.status < 400)
                throw(_remote_error(response.status; ambiguous, retry_after=hint))
            end
            delay = isnothing(hint) ? 2^(attempt - 1) : hint
        else
            delay = 2^(attempt - 1)
        end
        if delay > c.retry_budget - waited
            isnothing(response) && throw(_remote_error(503))
            throw(_remote_error(response.status; retry_after=delay))
        end
        c.sleeper(delay)
        waited += delay
    end
    error("unreachable retry state")
end

const DEPOSITIONS = "/api/deposit/depositions"

"""
    _endpoint(c, id) -> String

The URL of one deposition.
"""
_endpoint(c::Client, id) = origin(c) * DEPOSITIONS * "/" * checked_id(id)

"""
    create_deposition(c, metadata) -> Dict

`POST /api/deposit/depositions` with `metadata` plus `prereserve_doi=true`.
Not idempotent: an ambiguous failure must be reconciled, not repeated.
"""
create_deposition(c::Client, metadata::AbstractDict) = _request(c, "POST", origin(c) * DEPOSITIONS;
    body_factory=() -> JSON3.write(Dict("metadata" => merge(Dict{String,Any}(metadata), Dict("prereserve_doi" => true)))),
    expected=(201,))

"""
    get_deposition(c, id) -> Dict

`GET` one deposition.
"""
get_deposition(c::Client, id) = _request(c, "GET", _endpoint(c, id))

"""
    publish_deposition(c, id) -> Dict

`POST .../actions/publish`. Irreversible and not idempotent.
"""
publish_deposition(c::Client, id) = _request(c, "POST", _endpoint(c, id) * "/actions/publish";
    body_factory=() -> "{}", expected=(200, 202))

"""
    _bucket(c, deposit) -> String

The upload bucket URL of a draft, refused unless it is
`<origin>/api/files/<uuid>` for the client's own origin.
"""
function _bucket(c::Client, deposit)
    links = get(deposit, "links", Dict())
    url = links isa AbstractDict ? get(links, "bucket", nothing) : nothing
    url isa AbstractString || throw(RemoteError(502, "invalid_bucket", "Zenodo did not provide an upload bucket.", false, nothing))
    prefix = origin(c) * "/api/files/"
    startswith(url, prefix) &&
        occursin(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", url[length(prefix)+1:end]) ||
        throw(RemoteError(502, "unsafe_bucket", "Refusing an upload bucket outside the Zenodo origin or API path.", false, nothing))
    return String(url)
end

"""
    upload_file(c, deposit, path, filename) -> Dict

Stream one file into the draft's bucket with `PUT` (idempotent: a repeated
upload replaces the same object). Returns Zenodo's file record.
"""
function upload_file(c::Client, deposit, path::AbstractString, filename::AbstractString)
    occursin(FILENAME_PATTERN, filename) || throw(ArgumentError("Invalid file name"))
    _request(c, "PUT", _bucket(c, deposit) * "/" * filename;
        body_factory=() -> open(path, "r"), content_type="application/octet-stream",
        content_length=filesize(path), expected=(200, 201))
end
