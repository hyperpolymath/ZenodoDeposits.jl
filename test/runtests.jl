# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

using Test
using Dates, Logging, Sockets
using ZenodoDeposits
using ZenodoDeposits: DepositError, RemoteError, Client, transition, TRANSITIONS, STATES

include("fake_zenodo.jl")

"""
    sample_metadata(; kw...) -> Dict

Valid dataset metadata, with fields overridden by `kw`.
"""
sample_metadata(; kw...) = merge(Dict{String,Any}(
    "title" => "Measurements of a test system", "upload_type" => "dataset",
    "description" => "Synthetic data for testing.",
    "creators" => [Dict("name" => "Doe, Jane", "orcid" => "0000-0002-1825-0097", "affiliation" => "Test University")],
    "license" => "CC-BY-4.0", "publication_date" => "2026-01-01", "version" => "1.0.0",
    "keywords" => ["test"]), Dict{String,Any}(string(k) => v for (k, v) in kw))

"""
    sample_bundle(; files, metadata) -> Bundle

A bundle in a fresh temporary directory, with its checksum manifest.
"""
function sample_bundle(; files=Dict("data.csv" => "a,b\n1,2\n", "README.txt" => "Test bundle.\n"),
                       metadata=sample_metadata())
    dir = mktempdir()
    for (name, content) in files
        write(joinpath(dir, name), content)
    end
    write_checksums!(build_bundle(dir; metadata))
end

"""
    test_client(fake; env=:sandbox, sleeps=Int[], kw...) -> Client

A client whose transport is `fake`, whose sleeper records delays in `sleeps`
instead of sleeping, and whose token is the test token.
"""
test_client(fake; env=:sandbox, sleeps=Int[], kw...) =
    Client(env; environ=Dict((env == :sandbox ? "ZENODO_SANDBOX_TOKEN" : "ZENODO_TOKEN") => TEST_TOKEN),
           netrc="/nonexistent/netrc", transport=fake, sleeper=s -> push!(sleeps, s),
           clock=() -> DateTime(2026, 1, 1), kw...)

"""
    code_of(f) -> String

Run `f` and return the `code` of the DepositError or RemoteError it throws.
"""
function code_of(f)
    try
        f()
    catch e
        e isa Union{DepositError,RemoteError} && return e.code
        rethrow()
    end
    return "no error"
end

"""
    history(j) -> Vector{NTuple{3,Symbol}}

The transitions recorded in a journal, as `(from, action, outcome)`. A
write-ahead record is the persisted `:ambiguous` transition, so it is counted
as one: it is the state a crash or a lost response leaves behind.
"""
function history(j)
    s = ZenodoDeposits.read_json(joinpath(j.dir, "state.json"))
    [(Symbol(h["from"]), Symbol(h["action"]), h["outcome"] == "write_ahead" ? :ambiguous : Symbol(h["outcome"])) for h in s["history"]]
end

const SEEN = Set{NTuple{3,Symbol}}()
const JOURNALS = String[]

"""
    journal() -> Journal

A fresh journal, remembered so the redaction test can scan every journal.
"""
function journal()
    j = open_journal(joinpath(mktempdir(), "journal"))
    push!(JOURNALS, j.dir)
    return j
end

"""
    record!(j)

Add the journal's transitions to the coverage set.
"""
record!(j) = union!(SEEN, history(j))

@testset "ZenodoDeposits.jl" begin

@testset "metadata validation" begin
    m = validate_metadata(sample_metadata(); today=Date(2026, 6, 1))
    @test m["license"] == "cc-by-4.0"
    @test m["access_right"] == "open"
    @test m["creators"][1]["orcid"] == "0000-0002-1825-0097"
    bad(; kw...) = code_of(() -> validate_metadata(sample_metadata(; kw...); today=Date(2026, 6, 1)))
    @test bad(title="  ") == "invalid_metadata"
    @test bad(upload_type="blog") == "invalid_metadata"
    @test bad(upload_type="publication") == "invalid_metadata"
    @test code_of(() -> validate_metadata(sample_metadata(upload_type="publication", publication_type="article"))) == "no error"
    @test bad(publication_type="article") == "invalid_metadata"
    @test bad(upload_type="image") == "invalid_metadata"
    @test bad(creators=[]) == "invalid_metadata"
    @test bad(creators=[Dict("name" => "TODO")]) == "invalid_metadata"
    @test bad(creators=[Dict("name" => "Doe, Jane", "orcid" => "0000-0002-1825-0098")]) == "invalid_metadata"
    @test bad(creators=[Dict("name" => "Doe, Jane", "email" => "x@example.org")]) == "invalid_metadata"
    @test bad(doi="10.5281/zenodo.1") == "invalid_metadata"
    @test bad(prereserve_doi=true) == "invalid_metadata"
    @test bad(token="secret") == "invalid_metadata"
    @test bad(license=nothing) == "invalid_metadata"
    @test bad(license="cc by") == "invalid_metadata"
    @test bad(access_right="public") == "invalid_metadata"
    @test bad(access_right="embargoed") == "invalid_metadata"
    @test bad(access_right="embargoed", embargo_date="2026-01-01") == "invalid_metadata"
    @test code_of(() -> validate_metadata(sample_metadata(access_right="embargoed", embargo_date="2027-01-01"); today=Date(2026, 6, 1))) == "no error"
    @test bad(embargo_date="2027-01-01") == "invalid_metadata"
    @test bad(access_right="restricted") == "invalid_metadata"
    @test code_of(() -> validate_metadata(sample_metadata(access_right="restricted", access_conditions="On request."))) == "no error"
    @test bad(publication_date="2026-02-30") == "invalid_metadata"
    @test bad(publication_date="2030-01-01") == "invalid_metadata"
    @test bad(description="bell\a") == "invalid_metadata"
    @test bad(keywords="test") == "invalid_metadata"
    @test bad(related_identifiers=[Dict("identifier" => "x")]) == "invalid_metadata"
    @test bad(communities=[Dict("identifier" => Dict("a" => Dict("b" => Dict("c" => Dict("d" => Dict("e" => Dict("f" => Dict("g" => 1))))))))]) == "invalid_metadata"
    closed = validate_metadata(sample_metadata(access_right="closed", license=nothing) |> d -> (delete!(d, "license"); d))
    @test !haskey(closed, "license")
    @test validate_metadata(sample_metadata(communities=[Dict("identifier" => "zenodo")]))["communities"][1]["identifier"] == "zenodo"
end

@testset "bundles and checksums" begin
    dir = mktempdir()
    write(joinpath(dir, "a.txt"), "alpha\n")
    write(joinpath(dir, "b.txt"), "beta\n")
    b = build_bundle(dir; metadata=sample_metadata())
    @test [f.name for f in b.files] == ["a.txt", "b.txt"]
    @test code_of(() -> verify_bundle(b)) == "invalid_bundle"   # no manifest yet
    b = write_checksums!(b)
    @test [f.name for f in b.files] == ["a.txt", "b.txt", "checksums.sha256"]
    @test verify_bundle(b)
    manifest = read(joinpath(dir, "checksums.sha256"), String)
    @test manifest == "$(ZenodoDeposits.file_sha256(joinpath(dir, "a.txt")))  a.txt\n$(ZenodoDeposits.file_sha256(joinpath(dir, "b.txt")))  b.txt\n"
    @test b.files[1].md5 == bytes2hex(md5("alpha\n"))
    @test occursin("3 files", sprint(show, b))
    # Metadata from a JSON file.
    mpath = joinpath(mktempdir(), "m.json")
    write(mpath, JSON3.write(sample_metadata()))
    @test build_bundle(dir; metadata=mpath).metadata["title"] == "Measurements of a test system"
    # Tampering is detected both by the manifest and by the snapshot.
    write(joinpath(dir, "a.txt"), "ALPHA\n")
    @test code_of(() -> verify_bundle(b)) == "invalid_bundle"
    @test code_of(() -> build_bundle(dir; metadata=sample_metadata())) == "invalid_bundle"
    write(joinpath(dir, "a.txt"), "alpha\n")
    @test verify_bundle(b)
    write(joinpath(dir, "c.txt"), "new\n")
    @test code_of(() -> verify_bundle(b)) == "invalid_bundle"
    rm(joinpath(dir, "c.txt"))
    # Structural refusals.
    @test code_of(() -> build_bundle(mktempdir(); metadata=sample_metadata())) == "invalid_bundle"
    bad = mktempdir(); write(joinpath(bad, "has space.txt"), "x")
    @test code_of(() -> build_bundle(bad; metadata=sample_metadata())) == "invalid_bundle"
    nested = mktempdir(); mkdir(joinpath(nested, "sub"))
    @test code_of(() -> build_bundle(nested; metadata=sample_metadata())) == "invalid_bundle"
    linked = mktempdir(); write(joinpath(linked, "a.txt"), "x"); symlink(joinpath(linked, "a.txt"), joinpath(linked, "b.txt"))
    @test code_of(() -> build_bundle(linked; metadata=sample_metadata())) == "invalid_bundle"
    @test code_of(() -> build_bundle(dir; metadata=sample_metadata(title=""))) == "invalid_metadata"
    # A manifest with an extra entry is refused.
    other = mktempdir(); write(joinpath(other, "a.txt"), "x")
    write(joinpath(other, "checksums.sha256"), "$(repeat("0", 64))  ghost.txt\n")
    @test code_of(() -> build_bundle(other; metadata=sample_metadata())) == "invalid_bundle"
    @test ZenodoDeposits.fingerprint(b) == ZenodoDeposits.fingerprint(build_bundle(dir; metadata=sample_metadata()))
    @test ZenodoDeposits.fingerprint(b) != ZenodoDeposits.fingerprint(build_bundle(dir; metadata=sample_metadata(version="2")))
end

@testset "transition table" begin
    @test length(TRANSITIONS) == 15
    for ((from, action, outcome), (next, events)) in TRANSITIONS
        @test transition(from, action, outcome) == (next, events)
        @test count(==(:sent_publish), events) <= 1
    end
    for a in ZenodoDeposits.ACTIONS, o in ZenodoDeposits.OUTCOMES
        @test transition(:published, a, o) == (:published, Symbol[])
        @test !(:sent_publish in last(transition(:publish_uncertain, a, o)))
    end
    @test transition(:draft, :create, :ok) == (:draft, Symbol[])
    @test !ZenodoDeposits.permitted(:publish_uncertain, :publish)
    @test !ZenodoDeposits.permitted(:create_uncertain, :create)
end

@testset "happy path: deposit, then publish" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    s = deposit!(j, b; client=c)
    @test s["state"] == "uploaded"
    @test s["reserved_doi"] == "10.5072/zenodo.1001"
    @test count_requests(fake, "PUT", "/api/files/") == 3
    @test journal_state(j) == :uploaded
    # deposit! again is a no-op apart from a verifying GET.
    deposit!(j, b; client=c)
    @test count_requests(fake, "POST", "/api/deposit/depositions") == 1
    @test count_requests(fake, "PUT", "/api/files/") == 3
    @test code_of(() -> publish!(j; client=c)) == "confirmation_required"
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test journal_state(j) == :published
    @test status(j)["record_url"] == "https://sandbox.zenodo.org/records/1001"
    # Published is terminal: no further requests of any kind.
    n = length(fake.log)
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test deposit!(j, b; client=c)["state"] == "published"
    @test reconcile!(j; client=c)["state"] == "published"
    @test length(fake.log) == n
    @test code_of(() -> recover!(j, 1001; client=c)) == "not_permitted"
    receipt = ZenodoDeposits.read_json(joinpath(j.dir, "receipt.json"))
    @test receipt["doi"] == "10.5072/zenodo.1001"
    @test length(receipt["files"]) == 3
    cff = citation_cff(j)
    @test occursin("doi: \"10.5072/zenodo.1001\"", cff)
    @test occursin("family-names: \"Doe\"", cff)
    @test occursin("license: \"CC-BY-4.0\"", cff)
    @test all(==("Bearer " * TEST_TOKEN), fake.auth)
    @test history(j) == [(:empty, :create, :ambiguous), (:empty, :create, :ok), (:draft, :upload, :ok),
                        (:uploaded, :publish, :ambiguous), (:uploaded, :publish, :ok)]
    record!(j)
end

@testset "journal binding" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    @test code_of(() -> deposit!(j, sample_bundle(files=Dict("other.csv" => "x\n")); client=c)) == "bundle_mismatch"
    @test code_of(() -> deposit!(j, b; env=:production, client=test_client(FakeZenodo(env=:production); env=:production))) == "environment_mismatch"
    @test code_of(() -> publish!(j; confirm=true, client=test_client(FakeZenodo(env=:production); env=:production))) == "environment_mismatch"
    @test code_of(() -> publish!(journal(); confirm=true, client=c)) == "not_ready"
    write(joinpath(b.dir, "data.csv"), "changed")
    @test code_of(() -> deposit!(j, b; client=c)) == "invalid_bundle"
    @test count_requests(fake, "POST", "/api/deposit/depositions") == 1
    bad = journal(); write(joinpath(bad.dir, "state.json"), "{not json")
    @test code_of(() -> journal_state(bad)) == "corrupt_journal"
    busy = journal()
    @test code_of(() -> ZenodoDeposits.with_lock(() -> ZenodoDeposits.with_lock(() -> 1, busy.dir), busy.dir)) == "journal_busy"
    @test filemode(j.dir) & 0o777 == 0o700
    @test filemode(joinpath(j.dir, "state.json")) & 0o777 == 0o600
end

@testset "create: rejected, then retried" begin
    fake = fault!(FakeZenodo(), "POST", "/depositions", (400, nothing)); c = test_client(fake); j = journal()
    @test code_of(() -> deposit!(j, sample_bundle(); client=c)) == "zenodo_rejected"
    @test journal_state(j) == :empty
    @test status(j)["last_error"]["code"] == "zenodo_rejected"
    b = sample_bundle()
    j = journal()
    fault!(fake, "POST", "/depositions", (400, nothing))
    @test_throws RemoteError deposit!(j, b; client=c)
    @test deposit!(j, b; client=c)["state"] == "uploaded"
    @test isnothing(status(j)["last_error"])
    @test length(fake.deps) == 1
    record!(j)
end

@testset "crash-resume: create response lost" begin
    fake = fault!(FakeZenodo(), "POST", "/depositions", :lost); c = test_client(fake); b = sample_bundle(); j = journal()
    e = try deposit!(j, b; client=c) catch err; err end
    @test e isa RemoteError && e.ambiguous && e.code == "zenodo_unavailable"
    @test journal_state(j) == :create_uncertain
    @test length(fake.deps) == 1          # the draft exists remotely
    # Resuming never creates a second draft.
    @test code_of(() -> deposit!(j, b; client=c)) == "create_uncertain"
    @test count_requests(fake, "POST", "/api/deposit/depositions") == 1
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "not_ready"
    # Adoption is refused for a draft that is not ours.
    other = test_client(fake)
    foreign = ZenodoDeposits.create_deposition(other, validate_metadata(sample_metadata(title="Someone else")))
    @test code_of(() -> recover!(j, foreign["id"]; client=c)) == "recover_refused"
    @test code_of(() -> recover!(j, 999999; client=c)) == "zenodo_not_found"
    @test journal_state(j) == :create_uncertain
    @test recover!(j, 1001; client=c)["state"] == "draft"
    @test deposit!(j, b; client=c)["state"] == "uploaded"
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test count(r -> r[1] == "POST" && endswith(r[2], "/api/deposit/depositions"), fake.log) == 2   # ours + the foreign one
    record!(j)
end

@testset "crash-resume: create never sent" begin
    fake = fault!(FakeZenodo(), "POST", "/depositions", :before); c = test_client(fake); j = journal()
    e = try deposit!(j, sample_bundle(); client=c) catch err; err end
    @test e isa RemoteError && e.ambiguous
    @test journal_state(j) == :create_uncertain
    @test isempty(fake.deps)
    # Nothing was created, but the journal cannot know that: it stays uncertain.
    @test code_of(() -> deposit!(j, sample_bundle(); client=c)) in ("bundle_mismatch", "create_uncertain")
    @test isempty(fake.deps)
end

@testset "crash-resume: uploads" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    # The second file is rejected: the journal stays in draft with one file uploaded.
    fault!(fake, "PUT", "data.csv", (400, nothing))
    @test code_of(() -> deposit!(j, b; client=c)) == "zenodo_rejected"
    @test journal_state(j) == :draft
    @test count_requests(fake, "PUT", "README.txt") == 1
    # Resume uploads only what is missing.
    @test deposit!(j, b; client=c)["state"] == "uploaded"
    @test count_requests(fake, "PUT", "README.txt") == 1
    @test count_requests(fake, "PUT", "data.csv") == 2
    # 503 on an idempotent PUT is retried in place.
    fake2 = fault!(fault!(FakeZenodo(), "PUT", "README.txt", (503, nothing)), "PUT", "README.txt", :lost)
    sleeps = Int[]; j2 = journal()
    @test deposit!(j2, b; client=test_client(fake2; sleeps))["state"] == "uploaded"
    @test sleeps == [1, 2]
    @test count_requests(fake2, "PUT", "README.txt") == 3
    # An extra remote file blocks the upload until it is removed.
    fake3 = FakeZenodo(); c3 = test_client(fake3); j3 = journal()
    fault!(fake3, "PUT", "README.txt", (400, nothing))
    @test_throws RemoteError deposit!(j3, b; client=c3)
    add_remote_file!(fake3, 1001, "stray.bin", "x")
    @test code_of(() -> deposit!(j3, b; client=c3)) == "remote_files_unexpected"
    delete!(fake3.deps[1001]["files"], "stray.bin")
    @test deposit!(j3, b; client=c3)["state"] == "uploaded"
    # A changed remote file after verification blocks publishing.
    add_remote_file!(fake3, 1001, "data.csv", "tampered")
    @test code_of(() -> publish!(j3; confirm=true, client=c3)) == "remote_files_changed"
    @test code_of(() -> deposit!(j3, b; client=c3)) == "remote_files_changed"
    @test count_requests(fake3, "POST", "/actions/publish") == 0
    foreach(record!, (j, j2, j3))
end

@testset "publish: rejected, then retried" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    fault!(fake, "POST", "/actions/publish", (400, nothing))
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "zenodo_rejected"
    @test journal_state(j) == :uploaded
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test count_requests(fake, "POST", "/actions/publish") == 2   # a definite rejection may be retried
    record!(j)
end

@testset "crash-resume: publish response lost" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    fault!(fake, "POST", "/actions/publish", :lost)
    e = try publish!(j; confirm=true, client=c) catch err; err end
    @test e isa RemoteError && e.ambiguous
    @test journal_state(j) == :publish_uncertain
    @test code_of(() -> deposit!(j, b; client=c)) == "publish_uncertain"
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test count_requests(fake, "POST", "/actions/publish") == 1
    @test journal_state(j) == :published
    record!(j)
end

@testset "crash-resume: publish never reached Zenodo" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    fault!(fake, "POST", "/actions/publish", :before)
    @test_throws RemoteError publish!(j; confirm=true, client=c)
    @test journal_state(j) == :publish_uncertain
    # Resuming checks, finds it unpublished, and refuses to send again — twice.
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "publication_uncertain"
    @test journal_state(j) == :publish_uncertain
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "publication_uncertain"
    @test reconcile!(j; client=c)["state"] == "publish_uncertain"
    @test count_requests(fake, "POST", "/actions/publish") == 1
    # The documented way out: publish by hand on Zenodo, then reconcile.
    publish_by_hand!(fake, 1001)
    @test reconcile!(j; client=c)["state"] == "published"
    @test count_requests(fake, "POST", "/actions/publish") == 1
    record!(j)
end

@testset "crash-resume: publish 5xx and slow publication" begin
    fake = FakeZenodo(pending_gets=3); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "publication_pending"
    @test journal_state(j) == :publish_uncertain
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "publication_uncertain"
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test count_requests(fake, "POST", "/actions/publish") == 1
    # A 503 on the POST is not retried: it is ambiguous.
    fake2 = FakeZenodo(); c2 = test_client(fake2); j2 = journal()
    deposit!(j2, b; client=c2)
    fault!(fake2, "POST", "/actions/publish", (503, nothing))
    e = try publish!(j2; confirm=true, client=c2) catch err; err end
    @test e isa RemoteError && e.ambiguous
    @test journal_state(j2) == :publish_uncertain
    @test count_requests(fake2, "POST", "/actions/publish") == 1
    foreach(record!, (j, j2))
end

@testset "crash-resume: crash after receipt, before terminal state" begin
    fake = FakeZenodo(); c = test_client(fake); b = sample_bundle(); j = journal()
    deposit!(j, b; client=c)
    publish!(j; confirm=true, client=c)
    # Replay the state file as it was just after the write-ahead record.
    path = joinpath(j.dir, "state.json")
    s = ZenodoDeposits.read_json(path)
    s["state"] = "publish_uncertain"; s["doi"] = nothing
    ZenodoDeposits.atomic_json(path, s)
    @test publish!(j; confirm=true, client=c) == "10.5072/zenodo.1001"
    @test count_requests(fake, "POST", "/actions/publish") == 1
    # A receipt that disagrees is never overwritten.
    r = ZenodoDeposits.read_json(joinpath(j.dir, "receipt.json"))
    r["doi"] = "10.5072/zenodo.1"; ZenodoDeposits.atomic_json(joinpath(j.dir, "receipt.json"), r)
    s["state"] = "publish_uncertain"; ZenodoDeposits.atomic_json(path, s)
    @test code_of(() -> publish!(j; confirm=true, client=c)) == "receipt_conflict"
end

@testset "reconcile: published by hand" begin
    b = sample_bundle()
    # From draft (deposit! notices the website publication).
    fake = FakeZenodo(); c = test_client(fake); j = journal()
    fault!(fake, "PUT", "README.txt", (400, nothing))
    @test_throws RemoteError deposit!(j, b; client=c)
    @test reconcile!(j; client=c)["state"] == "draft"
    publish_by_hand!(fake, 1001)
    @test deposit!(j, b; client=c)["state"] == "published"
    # From uploaded, via reconcile! and via publish!.
    fake2 = FakeZenodo(); c2 = test_client(fake2); j2 = journal()
    deposit!(j2, b; client=c2)
    @test reconcile!(j2; client=c2)["state"] == "uploaded"
    publish_by_hand!(fake2, 1001)
    @test publish!(j2; confirm=true, client=c2) == "10.5072/zenodo.1001"
    @test count_requests(fake2, "POST", "/actions/publish") == 0
    fake3 = FakeZenodo(); c3 = test_client(fake3); j3 = journal()
    deposit!(j3, b; client=c3)
    publish_by_hand!(fake3, 1001)
    @test reconcile!(j3; client=c3)["state"] == "published"
    # Remote metadata edited by hand is detected and nothing is overwritten.
    fake4 = FakeZenodo(); c4 = test_client(fake4); j4 = journal()
    deposit!(j4, b; client=c4)
    fake4.deps[1001]["metadata"]["title"] = "Edited on the website"
    @test code_of(() -> publish!(j4; confirm=true, client=c4)) == "remote_metadata_changed"
    @test count_requests(fake4, "POST", "/actions/publish") == 0
    foreach(record!, (j, j2, j3))
end

@testset "every transition is exercised through the journal" begin
    @test SEEN == Set(keys(TRANSITIONS))
    missing = setdiff(Set(keys(TRANSITIONS)), SEEN)
    isempty(missing) || @info "Transitions not exercised" missing
end

@testset "rate limits: bounded backoff honouring Retry-After" begin
    fake = FakeZenodo(); sleeps = Int[]; c = test_client(fake; sleeps)
    fault!(fake, "POST", "/depositions", (429, 3))
    fault!(fake, "PUT", "README.txt", (429, nothing))
    fault!(fake, "PUT", "README.txt", (429, nothing))
    j = journal(); b = sample_bundle()
    @test deposit!(j, b; client=c)["state"] == "uploaded"
    @test sleeps == [3, 1, 2]
    @test length(fake.deps) == 1           # a 429'd POST is retried, never duplicated
    # A Retry-After beyond the budget is reported, not slept.
    fake2 = fault!(FakeZenodo(), "POST", "/depositions", (429, 3600)); sleeps2 = Int[]
    e = try deposit!(journal(), b; client=test_client(fake2; sleeps=sleeps2)) catch err; err end
    @test e isa RemoteError && e.code == "zenodo_rate_limited" && e.retry_after == 3600 && !e.ambiguous
    @test isempty(sleeps2)
    # Attempts are bounded.
    fake3 = FakeZenodo(); sleeps3 = Int[]
    for _ in 1:10; fault!(fake3, "POST", "/depositions", (429, nothing)); end
    @test code_of(() -> deposit!(journal(), b; client=test_client(fake3; sleeps=sleeps3))) == "zenodo_rate_limited"
    @test sleeps3 == [1, 2, 4]
    @test count_requests(fake3, "POST", "/depositions") == 4
    # Retry-After forms.
    clock = DateTime(2026, 1, 1, 0, 0, 0)
    @test ZenodoDeposits.retry_after_seconds("7", clock) == 7
    @test ZenodoDeposits.retry_after_seconds("Thu, 01 Jan 2026 00:00:30 GMT", clock) == 30
    @test ZenodoDeposits.retry_after_seconds("soon", clock) === nothing
    @test ZenodoDeposits.retry_after_seconds("99999999999999999999999", clock) == typemax(Int)
    @test ZenodoDeposits.retry_after_seconds("-5", clock) == 0
end

@testset "tokens: sources and redaction" begin
    env = Dict("ZENODO_SANDBOX_TOKEN" => TEST_TOKEN)
    c = Client(:sandbox; environ=env, netrc="/nonexistent")
    @test !occursin(TEST_TOKEN, sprint(show, c))
    @test !occursin(TEST_TOKEN, repr(c))
    @test sprint(show, c.token) == "[REDACTED]"
    @test occursin("sandbox", sprint(show, c))
    # Production needs its own variable; the sandbox token is never used for it.
    e = try Client(:production; environ=env, netrc="/nonexistent") catch err; err end
    @test e isa DepositError && e.code == "missing_token" && occursin("ZENODO_TOKEN", e.message)
    @test_throws ArgumentError Client(:staging; environ=env, netrc="/nonexistent")
    @test code_of(() -> Client(:sandbox; environ=Dict("ZENODO_SANDBOX_TOKEN" => "a b"), netrc="/nonexistent")) == "invalid_token"
    # netrc: used when the variable is unset; refused when readable by others.
    dir = mktempdir(); netrc = joinpath(dir, "netrc")
    write(netrc, "machine zenodo.org login me password prod-token\nmachine sandbox.zenodo.org\n  login me\n  password $(TEST_TOKEN)\n")
    chmod(netrc, 0o600)
    @test Client(:sandbox; environ=Dict{String,String}(), netrc).token.value == TEST_TOKEN
    @test Client(:production; environ=Dict{String,String}(), netrc).token.value == "prod-token"
    chmod(netrc, 0o644)
    e = try Client(:sandbox; environ=Dict{String,String}(), netrc) catch err; err end
    @test e isa DepositError && e.code == "unsafe_netrc" && !occursin(TEST_TOKEN, e.message)
    # Errors raised from transport failures never carry the token, though the
    # fake's exceptions and response bodies contain it.
    for kind in (:before, :lost, (500, nothing), (401, nothing), (302, nothing))
        fake = fault!(FakeZenodo(), "POST", "/depositions", kind)
        e = try deposit!(journal(), sample_bundle(); client=test_client(fake)) catch err; err end
        @test e isa Union{RemoteError,DepositError}
        @test !occursin(TEST_TOKEN, sprint(showerror, e))
        @test !occursin(TEST_TOKEN, sprint(show, e))
    end
    # The client refuses to send the token anywhere but the Zenodo API.
    @test_throws ArgumentError ZenodoDeposits._request(c, "GET", "https://example.org/api/x")
    @test_throws RemoteError ZenodoDeposits._bucket(c, Dict("links" => Dict("bucket" => "https://evil.example/api/files/00000000-0000-4000-8000-000000000001")))
end

@testset "tokens: real HTTP stack logs nothing sensitive" begin
    # A local server that echoes the Authorization header back in a 500 body.
    listener = Sockets.listen(Sockets.ip"127.0.0.1", 0)
    port = Int(Sockets.getsockname(listener)[2])
    server = HTTP.serve!(; server=listener, verbose=false) do req
        HTTP.Response(500, "echo: " * HTTP.header(req, "Authorization", ""))
    end
    try
        local_origin = "http://127.0.0.1:$port"
        transport = (m, u, h, b) -> ZenodoDeposits._http(m, replace(u, "https://sandbox.zenodo.org" => local_origin), h, b)
        c = Client(:sandbox; environ=Dict("ZENODO_SANDBOX_TOKEN" => TEST_TOKEN), netrc="/nonexistent",
                   transport, sleeper=_ -> nothing, attempts=2)
        logger = Test.TestLogger(; min_level=Logging.Debug)
        e = Logging.with_logger(logger) do
            try ZenodoDeposits.get_deposition(c, 1) catch err; err end
        end
        # Positive control: the server really does echo the credential back.
        raw = transport("GET", "https://sandbox.zenodo.org/api/x", ["Authorization" => "Bearer " * TEST_TOKEN], "")
        @test occursin(TEST_TOKEN, String(raw.body))
        @test e isa RemoteError && e.status == 500
        @test !occursin(TEST_TOKEN, sprint(showerror, e))
        @test all(r -> !occursin(TEST_TOKEN, string(r.message, r.kwargs)), logger.logs)
    finally
        close(server)
    end
end

@testset "tokens never reach journals or bundles" begin
    # Positive control: the scan finds a planted token.
    planted = mktempdir(); write(joinpath(planted, "leak.json"), "{\"auth\": \"Bearer " * TEST_TOKEN * "\"}")
    @test any(f -> occursin(TEST_TOKEN, read(joinpath(planted, f), String)), readdir(planted))
    @test !isempty(JOURNALS)
    for dir in JOURNALS, (root, _, files) in walkdir(dir), f in files
        @test !occursin(TEST_TOKEN, read(joinpath(root, f), String))
    end
    @test !any(k -> occursin("token", lowercase(k)), keys(ZenodoDeposits._fresh_state()))
end

@testset "Agda model is generated from this table" begin
    path = joinpath(@__DIR__, "..", "proofs", "agda", "ZenodoDeposits", "Transitions.agda")
    @test isfile(path)
    @test read(path, String) == ZenodoDeposits.render_agda_transitions()
end

@testset "command line" begin
    CLI = ZenodoDeposits.CLI
    b = sample_bundle()
    rm(joinpath(b.dir, "checksums.sha256"))    # the CLI writes the manifest
    mpath = joinpath(mktempdir(), "m.json"); write(mpath, JSON3.write(sample_metadata()))
    jdir = joinpath(mktempdir(), "j")
    run(args; client=nothing, stdin=devnull) = begin
        out = IOBuffer(); err = IOBuffer()
        code = CLI.main(args; stdin, stdout=out, stderr=err, environ=Dict("NETRC" => "/nonexistent/netrc"), client)
        (code, String(take!(out)), String(take!(err)))
    end
    @test run(["--help"])[1] == 0
    @test run(String[])[1] == 2
    @test run([b.dir])[1] == 2
    @test run([b.dir, "--metadata", mpath, "--sandbox", "--production"])[1] == 2
    @test run([b.dir, "--metadata", mpath, "--yes"])[1] == 2
    @test run([b.dir, "--metadata", mpath, "--bogus"])[1] == 2
    @test CLI.parse_args([b.dir, "--metadata", mpath]).env == :sandbox
    @test CLI.parse_args([b.dir, "--metadata", mpath, "--production"]).env == :production
    @test CLI.parse_args([b.dir, "--metadata", mpath]).journal == rstrip(b.dir, '/') * ".zenodo-journal"
    # No token in the (empty) environment: a clean error naming the variable.
    code, _, err = run([b.dir, "--metadata", mpath, "--journal", joinpath(mktempdir(), "x")])
    @test code == 1 && occursin("ZENODO_SANDBOX_TOKEN", err)
    fake = FakeZenodo(); c = test_client(fake)
    code, out, _ = run([b.dir, "--metadata", mpath, "--journal", jdir]; client=c)
    @test code == 0 && occursin("state: uploaded", out) && occursin("reserved DOI: 10.5072/zenodo.1001", out)
    @test isfile(joinpath(b.dir, "checksums.sha256"))
    code, _, err = run([b.dir, "--metadata", mpath, "--journal", jdir, "--publish"]; client=c)
    @test code == 1 && occursin("--yes", err)
    @test count_requests(fake, "POST", "/actions/publish") == 0
    fault!(fake, "POST", "/actions/publish", :before)
    @test run([b.dir, "--metadata", mpath, "--journal", jdir, "--publish", "--yes"]; client=c)[1] == 3
    @test run([b.dir, "--metadata", mpath, "--journal", jdir, "--publish", "--yes"]; client=c)[1] == 3
    publish_by_hand!(fake, 1001)
    code, out, _ = run([b.dir, "--metadata", mpath, "--journal", jdir, "--publish", "--yes"]; client=c)
    @test code == 0 && occursin("published DOI: 10.5072/zenodo.1001", out)
    @test count_requests(fake, "POST", "/actions/publish") == 1
    @test isfile(joinpath(@__DIR__, "..", "bin", "zenodo-deposit"))
    @test Sys.isexecutable(joinpath(@__DIR__, "..", "bin", "zenodo-deposit"))
end

@testset "live sandbox (opt-in)" begin
    netrc = get(ENV, "NETRC", joinpath(homedir(), ".netrc"))
    has_entry = isfile(netrc) && occursin(r"machine\s+sandbox\.zenodo\.org", read(netrc, String))
    has_token = !isempty(get(ENV, "ZENODO_SANDBOX_TOKEN", "")) || has_entry
    if get(ENV, "ZENODO_LIVE_TEST", "") == "1" && has_token
        b = sample_bundle(metadata=sample_metadata(title="ZenodoDeposits.jl live sandbox test $(now(UTC))"))
        j = journal()
        @test deposit!(j, b; env=:sandbox)["state"] == "uploaded"
        doi = publish!(j; confirm=true)
        @test startswith(doi, "10.5072/zenodo.")
        @info "Live sandbox test published" doi
    else
        @info "SKIPPED: live Zenodo sandbox test NOT RUN. It needs ZENODO_LIVE_TEST=1 and a sandbox token " *
              "(ZENODO_SANDBOX_TOKEN or a ~/.netrc entry for sandbox.zenodo.org). A skip is not a pass."
        @test_skip "live sandbox deposit and publish"
    end
end

include("aqua.jl")
include("jet.jl")

end
