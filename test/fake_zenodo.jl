# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# An in-memory model of the Zenodo deposition-v1 endpoints this package uses,
# injected as a Client transport. It never touches the network. Faults are
# scripted per request so every crash point and rate limit can be replayed.

using HTTP, JSON3, MD5

const TEST_TOKEN = "test-token-Zx9qK2vLmN4pR7sT"

"""
    Fault(method, pattern, kind)

A scripted fault, consumed by the first request whose method equals `method`
and whose URL contains `pattern`. `kind` is `:lost` (apply the request, then
lose the response), `:before` (fail before it reaches Zenodo), or an
`(status, retry_after)` tuple returned without applying the request.
"""
struct Fault
    method::String
    pattern::String
    kind::Any
end

"""
    FakeZenodo(; env=:sandbox, pending_gets=0)

The fake service. `pending_gets` makes a publish finish only after that many
subsequent GETs, as Zenodo's asynchronous publication sometimes does.
"""
mutable struct FakeZenodo
    origin::String
    prefix::String
    deps::Dict{Int,Dict{String,Any}}
    next_id::Int
    faults::Vector{Fault}
    log::Vector{Tuple{String,String}}
    auth::Vector{String}
    pending_gets::Int
    countdown::Dict{Int,Int}
end

FakeZenodo(; env::Symbol=:sandbox, pending_gets::Int=0) =
    FakeZenodo(env == :sandbox ? "https://sandbox.zenodo.org" : "https://zenodo.org",
               env == :sandbox ? "10.5072/zenodo." : "10.5281/zenodo.",
               Dict{Int,Dict{String,Any}}(), 1000, Fault[], Tuple{String,String}[], String[], pending_gets, Dict{Int,Int}())

"""
    fault!(fake, method, pattern, kind) -> fake

Script one fault.
"""
fault!(f::FakeZenodo, method, pattern, kind) = (push!(f.faults, Fault(method, pattern, kind)); f)

"""
    count_requests(fake, method, pattern) -> Int

How many requests with `method` and a URL containing `pattern` reached the
transport (including ones a fault then failed).
"""
count_requests(f::FakeZenodo, method, pattern) = count(r -> r[1] == method && occursin(pattern, r[2]), f.log)

_bucket_id(id) = "00000000-0000-4000-8000-" * lpad(string(id), 12, '0')

"""
    deposit_json(fake, id) -> Dict

The deposition as Zenodo's API returns it.
"""
function deposit_json(f::FakeZenodo, id::Int)
    d = f.deps[id]
    doi = f.prefix * string(id)
    done = d["submitted"] && get(f.countdown, id, 0) == 0
    Dict{String,Any}("id" => id, "record_id" => id, "submitted" => done, "state" => done ? "done" : "unsubmitted",
        "doi" => done ? doi : "",
        "metadata" => merge(d["metadata"], Dict{String,Any}("prereserve_doi" => Dict("doi" => doi, "recid" => id))),
        "links" => Dict("bucket" => f.origin * "/api/files/" * _bucket_id(id)),
        "files" => [Dict("id" => "f-$n", "filename" => n, "checksum" => v[1], "filesize" => v[2]) for (n, v) in d["files"]])
end

"""
    publish_by_hand!(fake, id)

Mark a deposition published, as if the owner had used the Zenodo website.
"""
publish_by_hand!(f::FakeZenodo, id) = (f.deps[Int(id)]["submitted"] = true; f)

"""
    add_remote_file!(fake, id, name, content)

Put a file into a draft out of band.
"""
add_remote_file!(f::FakeZenodo, id, name, content) =
    (f.deps[Int(id)]["files"][name] = (bytes2hex(md5(content)), sizeof(content)); f)

_json(status, x; headers=Pair{String,String}[]) = HTTP.Response(status, headers; body=JSON3.write(x))

"""
    (fake)(method, url, headers, body)

The transport entry point used by `Client`.
"""
function (f::FakeZenodo)(method::String, url::String, headers, body)
    push!(f.log, (method, url))
    push!(f.auth, last(only(filter(h -> first(h) == "Authorization", headers))))
    payload = body isa IO ? read(body) : Vector{UInt8}(codeunits(String(body)))
    i = findfirst(x -> x.method == method && occursin(x.pattern, url), f.faults)
    kind = isnothing(i) ? nothing : popat!(f.faults, i).kind
    kind === :before && error("connection reset before the request was sent ($(TEST_TOKEN))")
    if kind isa Tuple
        status, retry_after = kind
        h = isnothing(retry_after) ? Pair{String,String}[] : ["Retry-After" => string(retry_after)]
        # The body echoes the credential, as a misbehaving proxy might.
        return _json(status, Dict("message" => "fault", "echo" => "Bearer " * TEST_TOKEN); headers=h)
    end
    response = _route(f, method, url, payload)
    kind === :lost && error("connection reset after the request was applied ($(TEST_TOKEN))")
    return response
end

"""
    _route(fake, method, url, payload) -> HTTP.Response

Apply one request to the fake's state.
"""
function _route(f::FakeZenodo, method, url, payload)
    startswith(url, f.origin * "/api/") || return _json(404, Dict("message" => "not found"))
    path = url[length(f.origin)+1:end]
    if method == "POST" && path == "/api/deposit/depositions"
        id = (f.next_id += 1)
        metadata = JSON3.read(String(payload), Dict{String,Any})["metadata"]
        delete!(metadata, "prereserve_doi")
        f.deps[id] = Dict{String,Any}("metadata" => metadata, "submitted" => false,
                                      "files" => Dict{String,Tuple{String,Int}}())
        return _json(201, deposit_json(f, id))
    end
    m = match(r"^/api/deposit/depositions/([0-9]+)(/actions/publish)?$", path)
    if !isnothing(m)
        id = parse(Int, m[1])
        haskey(f.deps, id) || return _json(404, Dict("message" => "not found"))
        if method == "GET" && isnothing(m[2])
            c = get(f.countdown, id, 0)
            c > 0 && (f.countdown[id] = c - 1)
            return _json(200, deposit_json(f, id))
        elseif method == "POST" && !isnothing(m[2])
            f.deps[id]["submitted"] && return _json(400, Dict("message" => "already published"))
            f.deps[id]["submitted"] = true
            f.pending_gets > 0 && (f.countdown[id] = f.pending_gets)
            return _json(202, deposit_json(f, id))
        end
    end
    m = match(r"^/api/files/([0-9a-f-]+)/([A-Za-z0-9_.-]+)$", path)
    if method == "PUT" && !isnothing(m)
        id = findfirst(k -> _bucket_id(k) == m[1], collect(keys(f.deps)))
        isnothing(id) && return _json(404, Dict("message" => "no bucket"))
        dep_id = collect(keys(f.deps))[id]
        f.deps[dep_id]["submitted"] && return _json(403, Dict("message" => "published"))
        checksum = "md5:" * bytes2hex(md5(payload))
        f.deps[dep_id]["files"][m[2]] = (checksum, length(payload))
        return _json(201, Dict("key" => m[2], "checksum" => checksum, "size" => length(payload)))
    end
    return _json(405, Dict("message" => "unsupported"))
end
