# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# The deposit journal: a locked, atomically written state file that makes
# deposit! and publish! resumable and idempotent.
#
# Write-ahead rule. Before a non-idempotent request (create, publish) the
# journal persists `transition(state, action, :ambiguous)` — the state a crash
# or lost response must leave behind. After a definite outcome it persists
# `transition(state, action, outcome)` computed from the state *before* the
# write-ahead. Every persisted state is therefore a state of the model in
# `proofs/agda`, reached by a trace of the model.

const SCHEMA_VERSION = "1"

"""
    Journal

A handle on a journal directory created by [`open_journal`](@ref). It holds
no state in memory: every operation takes the directory lock and re-reads
`state.json`, so two processes cannot interleave and a crash loses nothing.
"""
struct Journal
    dir::String
end

"""
    show(io, j::Journal)

Print the journal directory.
"""
Base.show(io::IO, j::Journal) = print(io, "Journal(", repr(j.dir), ")")

"""
    open_journal(statedir) -> Journal

Open (creating if needed, mode 0700) the journal directory `statedir`. One
journal records one deposition. Never put tokens in it; this package never
does.
"""
function open_journal(statedir::AbstractString)
    dir = abspath(statedir)
    private_dir(dir)
    return Journal(dir)
end

_state_path(j::Journal) = joinpath(j.dir, "state.json")
_receipt_path(j::Journal) = joinpath(j.dir, "receipt.json")

"""
    _now() -> String

The current UTC time as an ISO 8601 string with a `Z` suffix.
"""
_now() = string(now(UTC)) * "Z"

"""
    _fresh_state() -> Dict{String,Any}

The state of a journal that has never been used.
"""
_fresh_state() = Dict{String,Any}("schema_version" => SCHEMA_VERSION, "api_version" => API_VERSION,
    "state" => "empty", "environment" => nothing, "fingerprint" => nothing, "metadata" => nothing,
    "identity" => nothing, "files" => nothing, "deposition_id" => nothing, "reserved_doi" => nothing,
    "doi" => nothing, "record_url" => nothing, "created_at" => nothing, "updated_at" => nothing,
    "published_at" => nothing, "last_error" => nothing, "history" => Any[])

"""
    _load(j) -> Dict{String,Any}

Read and check the journal state, or return a fresh state if there is none.
"""
function _load(j::Journal)
    path = _state_path(j)
    islink(path) && fail("unsafe_storage", "state.json must not be a symlink.")
    isfile(path) || return _fresh_state()
    s = try
        read_json(path)
    catch
        fail("corrupt_journal", "state.json is not valid JSON. Restore it from backup; do not delete it while a deposition exists.")
    end
    get(s, "schema_version", nothing) == SCHEMA_VERSION && get(s, "state", nothing) in map(String, STATES) ||
        fail("corrupt_journal", "state.json has an unknown schema version or state.")
    return s
end

"""
    _state(s) -> Symbol

The current state of a loaded journal as a symbol.
"""
_state(s) = Symbol(s["state"])

"""
    _persist!(j, s)

Stamp `updated_at` and write the state atomically.
"""
function _persist!(j::Journal, s)
    s["updated_at"] = _now()
    atomic_json(_state_path(j), s)
end

"""
    _settle!(j, s, from, action, outcome) -> Symbol

Apply `transition(from, action, outcome)`, record it in the history and
persist it. `from` is the state before any write-ahead record.
"""
function _settle!(j::Journal, s, from::Symbol, action::Symbol, outcome::Symbol)
    next, events = transition(from, action, outcome)
    s["state"] = String(next)
    push!(s["history"], Dict{String,Any}("at" => _now(), "action" => String(action), "outcome" => String(outcome),
        "from" => String(from), "to" => String(next), "events" => map(String, events)))
    _persist!(j, s)
    return next
end

"""
    _advance!(j, s, action, outcome) -> Symbol

[`_settle!`](@ref) from the current state.
"""
_advance!(j::Journal, s, action::Symbol, outcome::Symbol) = _settle!(j, s, _state(s), action, outcome)

"""
    _write_ahead!(j, s, action) -> Symbol

Persist the state that an ambiguous outcome of `action` leads to, before the
request is sent, so that a crash at any later point is recorded as uncertain.
"""
function _write_ahead!(j::Journal, s, action::Symbol)
    from = _state(s)
    next, _ = transition(from, action, :ambiguous)
    next == from && fail("internal_error", "No write-ahead state for $action in $from.")
    s["state"] = String(next)
    push!(s["history"], Dict{String,Any}("at" => _now(), "action" => String(action), "outcome" => "write_ahead",
        "from" => String(from), "to" => String(next), "events" => String[]))
    _persist!(j, s)
    return from
end

"""
    _require(s, action)

Fail with `not_permitted` unless the transition table allows `action` in the
current state.
"""
function _require(s, action::Symbol)
    permitted(_state(s), action) ||
        fail("not_permitted", "`$action` is not permitted in state `$(s["state"])`.")
end

"""
    _remember_error!(j, s, e)

Record a sanitised summary of `e` in `last_error`. Only this package's own
error types are copied; anything else is recorded generically, because raw
exceptions may carry URLs or headers.
"""
function _remember_error!(j::Journal, s, e)
    s["last_error"] = e isa Union{RemoteError,DepositError} ?
        Dict{String,Any}("code" => e.code, "message" => e.message, "at" => _now()) :
        Dict{String,Any}("code" => "operation_failed", "message" => "The operation failed locally. Retry it; it reconciles before acting.", "at" => _now())
    _persist!(j, s)
end

"""
    _client(s, client) -> Client

The client for the journal's bound environment, building one from the
environment/netrc when `client` is `nothing`.
"""
function _client(s, client)
    env = Symbol(s["environment"])
    isnothing(client) && return Client(env)
    client isa Client || throw(ArgumentError("client must be a ZenodoDeposits.Client"))
    client.env == env || fail("environment_mismatch", "This journal is bound to $env; the client is for $(client.env).")
    return client
end

"""
    _bind!(j, s, bundle, env)

On first use, bind the journal to `env` and the bundle's fingerprint, files
and metadata. Afterwards refuse a different environment or bundle.
"""
function _bind!(j::Journal, s, bundle::Bundle, env::Symbol)
    haskey(ORIGINS, env) || throw(ArgumentError("env must be :sandbox or :production"))
    if isnothing(s["environment"])
        s["environment"] = String(env)
        s["fingerprint"] = fingerprint(bundle)
        s["metadata"] = bundle.metadata
        s["identity"] = identity_fields(bundle.metadata)
        s["files"] = [Dict{String,Any}("name" => f.name, "size" => f.size, "sha256" => f.sha256, "md5" => f.md5)
                      for f in bundle.files]
        _persist!(j, s)
    else
        s["environment"] == String(env) ||
            fail("environment_mismatch", "This journal is bound to $(s["environment"]). Use a separate journal for $env.")
        s["fingerprint"] == fingerprint(bundle) ||
            fail("bundle_mismatch", "This journal is bound to a different bundle (files or metadata changed). Use a new journal for a new deposit.")
    end
end

"""
    _is_published(deposit) -> Bool

Whether Zenodo reports the deposition as submitted and done.
"""
_is_published(deposit) = get(deposit, "submitted", false) === true && get(deposit, "state", "") == "done"

"""
    _identity_matches(expected, metadata) -> Bool

Compare the identity fields recorded at bind time with a remote deposition's
metadata, ignoring fields this package did not send.
"""
function _identity_matches(expected::AbstractDict, metadata)
    metadata isa AbstractDict || return false
    actual = identity_fields(metadata)
    all(isnothing(v) || get(actual, k, nothing) == v for (k, v) in expected)
end

"""
    _check_remote(s, c, deposit) -> String

Check that `deposit` is this journal's deposition with unchanged identifying
metadata and the reserved DOI. Returns the DOI.
"""
function _check_remote(s, c::Client, deposit)
    checked_id(get(deposit, "id", nothing)) == s["deposition_id"] ||
        fail("deposition_mismatch", "Zenodo returned a different deposition. Refusing to continue.")
    metadata = get(deposit, "metadata", nothing)
    _identity_matches(s["identity"], metadata) ||
        fail("remote_metadata_changed", "The Zenodo deposition's title, creators, type, licence, version or date differ from this journal's bundle. Review it on Zenodo; nothing was overwritten.")
    doi = _is_published(deposit) ? checked_doi(c, get(deposit, "doi", get(metadata, "doi", nothing))) : reserved_doi(c, deposit)
    isnothing(s["reserved_doi"]) || doi == s["reserved_doi"] ||
        fail("doi_changed", "The Zenodo DOI differs from the DOI reserved for this journal.")
    return doi
end

"""
    _remote_file(entry) -> Union{Tuple{String,String,Int},Nothing}

Normalise a Zenodo file record (deposition listing or bucket response) to
`(name, md5, size)`, or `nothing` if it is malformed.
"""
function _remote_file(entry)
    entry isa AbstractDict || return nothing
    name = get(entry, "filename", get(entry, "key", nothing))
    checksum = get(entry, "checksum", nothing)
    raw = get(entry, "filesize", get(entry, "size", nothing))
    size = raw isa AbstractString ? tryparse(Int, raw) : raw
    name isa AbstractString && checksum isa AbstractString && size isa Integer && !(size isa Bool) || return nothing
    return (String(name), replace(lowercase(checksum), r"^md5:" => ""), Int(size))
end

"""
    _remote_files(deposit) -> Dict{String,Tuple{String,Int}}

The draft's files as `name => (md5, size)`; malformed listings are refused.
"""
function _remote_files(deposit)
    files = get(deposit, "files", Any[])
    files isa AbstractVector || fail("remote_files_invalid", "Zenodo returned an invalid file listing.")
    out = Dict{String,Tuple{String,Int}}()
    for entry in files
        file = _remote_file(entry)
        isnothing(file) && fail("remote_files_invalid", "Zenodo returned an invalid file record.")
        haskey(out, file[1]) && fail("remote_files_invalid", "Zenodo lists a file twice: $(file[1])")
        out[file[1]] = (file[2], file[3])
    end
    return out
end

"""
    _files_match(s, remote) -> Bool

Whether the remote files are exactly the journal's files: same names, MD5
checksums and sizes, nothing missing and nothing extra.
"""
function _files_match(s, remote)
    length(remote) == length(s["files"]) &&
        all(get(remote, f["name"], nothing) == (f["md5"], f["size"]) for f in s["files"])
end

"""
    deposit!(journal, bundle; env=:sandbox, client=nothing) -> Dict

Phase 1: create a Zenodo draft with a reserved DOI and upload every file of
`bundle`, then verify the remote names, sizes and MD5 checksums. Nothing is
published.

Safe to call again after any failure or crash: it resumes from the journal,
re-uploads only missing or differing files, and never creates a second
deposition. If a create request's outcome is unknown the journal enters
`create_uncertain`; find the draft on Zenodo and call [`recover!`](@ref).

Sandbox is the default; production requires `env=:production`. The token is
read by [`Client`](@ref). Returns [`status`](@ref).
"""
function deposit!(j::Journal, bundle::Bundle; env::Symbol=:sandbox, client=nothing)
    verify_bundle(bundle)
    with_lock(j.dir) do
        s = _load(j)
        _bind!(j, s, bundle, env)
        _state(s) == :published && return status(s)
        c = _client(s, client)
        try
            _state(s) == :empty && _create!(j, s, bundle, c)
            _state(s) == :create_uncertain && fail("create_uncertain",
                "A create request may have reached Zenodo. Find the draft in your Zenodo uploads and call recover!(journal, deposition_id). Creating another one could duplicate it.")
            _state(s) == :publish_uncertain && fail("publish_uncertain",
                "A publish request may have reached Zenodo. Call publish!(journal; confirm=true) or reconcile!(journal) to check.")
            _state(s) in (:draft, :uploaded) && _upload!(j, s, bundle, c)
        catch e
            _remember_error!(j, s, e)
            rethrow()
        end
        isnothing(s["last_error"]) || (s["last_error"] = nothing; _persist!(j, s))
        return status(s)
    end
end

"""
    _create!(j, s, bundle, c)

Create the draft under the write-ahead rule.
"""
function _create!(j::Journal, s, bundle::Bundle, c::Client)
    _require(s, :create)
    from = _write_ahead!(j, s, :create)
    deposit = try
        create_deposition(c, bundle.metadata)
    catch e
        e isa RemoteError && !e.ambiguous && _settle!(j, s, from, :create, :rejected)
        rethrow()
    end
    # From here a deposition exists. Any failure leaves `create_uncertain`.
    id = checked_id(get(deposit, "id", nothing))
    s["deposition_id"] = id
    s["reserved_doi"] = reserved_doi(c, deposit)
    _check_remote(s, c, deposit)
    s["created_at"] = _now()
    _settle!(j, s, from, :create, :ok)
end

"""
    _upload!(j, s, bundle, c)

Upload missing or differing files to the draft and verify the full listing.
If Zenodo already shows the deposition as published (for example, published
by hand), reconcile to `published` instead.
"""
function _upload!(j::Journal, s, bundle::Bundle, c::Client)
    deposit = get_deposition(c, s["deposition_id"])
    _check_remote(s, c, deposit)
    if _is_published(deposit)
        _require(s, :reconcile)
        return _finish!(j, s, c, deposit, _state(s), :reconcile)
    end
    remote = _remote_files(deposit)
    expected = Set(f.name for f in bundle.files)
    extra = setdiff(Set(keys(remote)), expected)
    isempty(extra) || fail("remote_files_unexpected",
        "The draft contains files that are not in the bundle: $(join(sort!(collect(extra)), ", ")). Remove them on Zenodo, then retry.")
    if _state(s) == :draft
        _require(s, :upload)
        try
            for f in bundle.files
                get(remote, f.name, nothing) == (f.md5, f.size) && continue
                record = _remote_file(upload_file(c, deposit, joinpath(bundle.dir, f.name), f.name))
                record == (f.name, f.md5, f.size) ||
                    fail("upload_mismatch", "Zenodo's checksum or size for $(f.name) does not match the local file. Retry deposit!.")
            end
            deposit = get_deposition(c, s["deposition_id"])
            _check_remote(s, c, deposit)
            _files_match(s, _remote_files(deposit)) ||
                fail("remote_files_mismatch", "The draft's files do not match the bundle after upload. Retry deposit!.")
        catch
            _advance!(j, s, :upload, :rejected)
            rethrow()
        end
        _advance!(j, s, :upload, :ok)
    else
        _files_match(s, remote) || fail("remote_files_changed",
            "The draft's files changed after they were verified. Review the draft on Zenodo before publishing.")
    end
end

"""
    publish!(journal; confirm=false, client=nothing) -> String

Phase 2: publish the verified draft and return its DOI. **Irreversible**: a
published DOI cannot be deleted, so `confirm=true` is required.

The publish request is sent at most once per journal. If its outcome is
unknown the journal enters `publish_uncertain`; calling `publish!` again then
only reads the deposition from Zenodo and never sends another publish
request. A journal already `published` returns its DOI without any request.
"""
function publish!(j::Journal; confirm::Bool=false, client=nothing)
    confirm === true || fail("confirmation_required",
        "Publishing mints a permanent DOI and cannot be undone. Call publish!(journal; confirm=true).")
    with_lock(j.dir) do
        s = _load(j)
        _state(s) == :published && return String(s["doi"])
        _state(s) in (:uploaded, :publish_uncertain) ||
            fail("not_ready", "Nothing to publish yet (state `$(s["state"])`). Run deposit! until it reports `uploaded`.")
        c = _client(s, client)
        try
            return _publish_locked!(j, s, c)
        catch e
            _remember_error!(j, s, e)
            rethrow()
        end
    end
end

"""
    _publish_locked!(j, s, c) -> String

Publish or reconcile while holding the journal lock.
"""
function _publish_locked!(j::Journal, s, c::Client)
    _state(s) == :publish_uncertain && return _reconcile_locked!(j, s, c; raise=true)
    deposit = get_deposition(c, s["deposition_id"])
    _check_remote(s, c, deposit)
    _is_published(deposit) && return _finish!(j, s, c, deposit, :uploaded, :reconcile)
    _files_match(s, _remote_files(deposit)) || fail("remote_files_changed",
        "The draft's files changed after they were verified. Review the draft on Zenodo; nothing was published.")
    _require(s, :publish)
    from = _write_ahead!(j, s, :publish)
    response = try
        publish_deposition(c, s["deposition_id"])
    catch e
        e isa RemoteError && !e.ambiguous && _settle!(j, s, from, :publish, :rejected)
        rethrow()
    end
    # The request reached Zenodo. Every path below leaves publish_uncertain
    # unless publication is confirmed; the request is never repeated.
    checked_id(get(response, "id", nothing)) == s["deposition_id"] ||
        fail("deposition_mismatch", "Zenodo's publish response names a different deposition. Reconcile before doing anything else.")
    deposit = _is_published(response) ? response : get_deposition(c, s["deposition_id"])
    _check_remote(s, c, deposit)
    _is_published(deposit) && return _finish!(j, s, c, deposit, from, :publish)
    fail("publication_pending", "Zenodo accepted the publish request but has not finished. Call publish!(journal; confirm=true) again later; it will only check, never re-send.")
end

"""
    reconcile!(journal; client=nothing) -> Dict

Read the deposition from Zenodo and move the journal to `published` if
Zenodo shows it published (for example after a lost publish response, or a
publish done by hand on the website). Never sends a create or publish
request. Returns [`status`](@ref).
"""
function reconcile!(j::Journal; client=nothing)
    with_lock(j.dir) do
        s = _load(j)
        _state(s) == :published && return status(s)
        _require(s, :reconcile)
        c = _client(s, client)
        try
            _reconcile_locked!(j, s, c; raise=false)
        catch e
            _remember_error!(j, s, e)
            rethrow()
        end
        return status(s)
    end
end

"""
    _reconcile_locked!(j, s, c; raise) -> Union{String,Nothing}

GET the deposition: if published, finish and return the DOI; otherwise
record a rejected reconcile (the state does not change) and, when `raise`,
fail with `publication_uncertain`.
"""
function _reconcile_locked!(j::Journal, s, c::Client; raise::Bool)
    deposit = get_deposition(c, s["deposition_id"])
    _check_remote(s, c, deposit)
    _is_published(deposit) && return _finish!(j, s, c, deposit, _state(s), :reconcile)
    _advance!(j, s, :reconcile, :rejected)
    raise && _state(s) == :publish_uncertain && fail("publication_uncertain",
        "Zenodo does not show this deposition as published yet. A publish request was already sent, so it will not be sent again. " *
        "Call publish!(journal; confirm=true) or reconcile!(journal) later, or publish the draft on the Zenodo website and then reconcile.")
    return nothing
end

"""
    recover!(journal, deposition_id; client=nothing) -> Dict

Leave `create_uncertain` by adopting the draft the lost create request made.
Find its id in your Zenodo uploads. The draft must be unpublished, have no
files, and match this journal's title, creators and other identity fields.
Returns [`status`](@ref).

If you have confirmed that no draft was created, start a new journal; this
one stays uncertain so that a draft is never created twice.
"""
function recover!(j::Journal, deposition_id; client=nothing)
    with_lock(j.dir) do
        s = _load(j)
        _require(s, :recover)
        c = _client(s, client)
        try
            id = checked_id(deposition_id)
            deposit = get_deposition(c, id)
            checked_id(get(deposit, "id", nothing)) == id || fail("deposition_mismatch", "Zenodo returned a different deposition.")
            _is_published(deposit) && fail("recover_refused", "That deposition is already published; it cannot be adopted.")
            isempty(_remote_files(deposit)) || fail("recover_refused", "That draft already has files; adopt only the empty draft created by this journal.")
            _identity_matches(s["identity"], get(deposit, "metadata", nothing)) ||
                fail("recover_refused", "That draft's title, creators or other identity fields do not match this journal.")
            s["deposition_id"] = id
            s["reserved_doi"] = reserved_doi(c, deposit)
            s["created_at"] = _now()
            s["last_error"] = nothing
            _advance!(j, s, :recover, :ok)
        catch e
            _remember_error!(j, s, e)
            rethrow()
        end
        return status(s)
    end
end

"""
    _finish!(j, s, c, deposit, from, action) -> String

Record a confirmed publication: check the DOI, write `receipt.json` (before
the terminal state, so a crash here is recovered by reconciling, never by a
second publish request) and settle `(from, action, :ok)`.
"""
function _finish!(j::Journal, s, c::Client, deposit, from::Symbol, action::Symbol)
    doi = checked_doi(c, get(deposit, "doi", get(get(deposit, "metadata", Dict()), "doi", nothing)))
    isnothing(s["reserved_doi"]) || doi == s["reserved_doi"] ||
        fail("doi_changed", "The published DOI differs from the reserved DOI.")
    s["doi"] = doi
    s["record_url"] = origin(c) * "/records/" * checked_id(get(deposit, "record_id", s["deposition_id"]))
    s["published_at"] = something(s["published_at"], _now())
    s["last_error"] = nothing
    path = _receipt_path(j)
    islink(path) && fail("unsafe_storage", "receipt.json must not be a symlink.")
    receipt = Dict{String,Any}("api_version" => API_VERSION, "environment" => s["environment"],
        "deposition_id" => s["deposition_id"], "doi" => doi, "record_url" => s["record_url"],
        "fingerprint" => s["fingerprint"], "files" => s["files"], "metadata" => s["metadata"])
    if isfile(path)
        previous = read_json(path)
        all(get(previous, k, nothing) == v for (k, v) in receipt if k != "published_at") ||
            fail("receipt_conflict", "An existing receipt.json disagrees with this publication.")
        s["published_at"] = get(previous, "published_at", s["published_at"])
    else
        receipt["published_at"] = s["published_at"]
        atomic_json(path, receipt)
    end
    _settle!(j, s, from, action, :ok)
    return doi
end

"""
    status(journal) -> Dict{String,Any}

A public summary of the journal: state, environment, deposition id, reserved
and final DOI, record URL, timestamps and the last sanitised error.
"""
status(j::Journal) = status(_load(j))

"""
    status(s::AbstractDict) -> Dict{String,Any}

The public summary of a loaded journal state.
"""
status(s::AbstractDict) = Dict{String,Any}(k => s[k] for k in ("state", "environment", "deposition_id",
    "reserved_doi", "doi", "record_url", "created_at", "updated_at", "published_at", "last_error", "api_version"))

"""
    journal_state(journal) -> Symbol

The journal's current state, one of [`STATES`](@ref).
"""
journal_state(j::Journal) = _state(_load(j))

"""
    doi(journal) -> Union{String,Nothing}

The published DOI, or `nothing` before publication.
"""
doi(j::Journal) = _load(j)["doi"]

"""
    _yaml(x) -> String

Quote a value as a YAML scalar. JSON strings are valid YAML double-quoted
scalars.
"""
_yaml(x) = JSON3.write(string(x))

"""Zenodo licence ids with a known SPDX equivalent, for CITATION.cff."""
const SPDX_LICENSES = Dict("cc-by-4.0" => "CC-BY-4.0", "cc-by-sa-4.0" => "CC-BY-SA-4.0", "cc0-1.0" => "CC0-1.0",
    "cc-by-nc-4.0" => "CC-BY-NC-4.0", "mit" => "MIT", "apache-2.0" => "Apache-2.0", "mpl-2.0" => "MPL-2.0",
    "bsd-3-clause" => "BSD-3-Clause", "gpl-3.0-or-later" => "GPL-3.0-or-later", "lgpl-3.0-or-later" => "LGPL-3.0-or-later")

"""
    citation_cff(journal) -> String

A `CITATION.cff` (version 1.2.0) for a published journal, with the DOI,
title, creators (and ORCIDs), licence, version and record URL. Write it into
your source repository; it is never added to the deposited bundle, whose
checksums are already fixed.
"""
function citation_cff(j::Journal)
    s = _load(j)
    _state(s) == :published || fail("not_published", "A citation is available only after publication.")
    m = s["metadata"]
    io = IOBuffer()
    println(io, "cff-version: 1.2.0")
    println(io, "message: \"If you use this work, please cite it as below.\"")
    println(io, "type: ", m["upload_type"] == "software" ? "software" : "dataset")
    println(io, "title: ", _yaml(m["title"]))
    println(io, "doi: ", _yaml(s["doi"]))
    println(io, "url: ", _yaml(s["record_url"]))
    println(io, "date-released: ", _yaml(get(m, "publication_date", first(s["published_at"], 10))))
    haskey(m, "version") && println(io, "version: ", _yaml(m["version"]))
    spdx = get(SPDX_LICENSES, get(m, "license", ""), nothing)
    isnothing(spdx) || println(io, "license: ", _yaml(spdx))
    println(io, "authors:")
    for c in m["creators"]
        parts = split(c["name"], ", "; limit=2)
        if length(parts) == 2
            println(io, "  - family-names: ", _yaml(parts[1]))
            println(io, "    given-names: ", _yaml(parts[2]))
        else
            println(io, "  - name: ", _yaml(c["name"]))
        end
        haskey(c, "orcid") && println(io, "    orcid: ", _yaml("https://orcid.org/" * c["orcid"]))
        haskey(c, "affiliation") && !isempty(c["affiliation"]) && println(io, "    affiliation: ", _yaml(c["affiliation"]))
    end
    return String(take!(io))
end
