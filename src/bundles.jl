# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# A bundle is a flat directory of regular files plus validated metadata. Its
# identity is the SHA-256 of every file and the canonical metadata.

const MANIFEST = "checksums.sha256"
const FILENAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"
const MAX_FILES = 100
const MAX_BUNDLE_BYTES = 50_000_000_000

"""
    BundleFile(name, size, sha256, md5)

One file of a [`Bundle`](@ref): its name, size in bytes, SHA-256 (the
provenance identity) and MD5 (compared with what Zenodo reports).
"""
struct BundleFile
    name::String
    size::Int
    sha256::String
    md5::String
end

"""
    Bundle

A validated deposit: `dir` (absolute path of a flat directory), `metadata`
(normalised by [`validate_metadata`](@ref)) and `files` (a sorted snapshot of
every file, including the `checksums.sha256` manifest when present). Build one
with [`build_bundle`](@ref).
"""
struct Bundle
    dir::String
    metadata::Dict{String,Any}
    files::Vector{BundleFile}
end

"""
    show(io, b::Bundle)

Print a one-line summary of the bundle.
"""
Base.show(io::IO, b::Bundle) =
    print(io, "Bundle(", repr(b.dir), ", ", length(b.files), " files, title=", repr(b.metadata["title"]), ")")

"""
    bundle_error(message)

Throw a [`DepositError`](@ref) with code `invalid_bundle`.
"""
bundle_error(message) = fail("invalid_bundle", message)

"""
    _bundle_names(dir) -> Vector{String}

List the bundle directory, refusing anything but regular files with safe
names, and enforcing Zenodo's file-count and total-size limits.
"""
function _bundle_names(dir::AbstractString)
    isdir(dir) && !islink(dir) || bundle_error("Bundle must be an existing directory, not a symlink: $dir")
    names = sort!(readdir(dir))
    isempty(names) && bundle_error("Bundle directory is empty.")
    length(names) <= MAX_FILES || bundle_error("Zenodo accepts at most $MAX_FILES files per record.")
    total = 0
    for name in names
        path = joinpath(dir, name)
        occursin(FILENAME_PATTERN, name) ||
            bundle_error("File name `$name` is not allowed. Use letters, digits, `_`, `.` and `-`, starting with a letter or digit.")
        islink(path) && bundle_error("Bundle must not contain symlinks: $name")
        isfile(path) || bundle_error("Bundle must be flat (regular files only): $name")
        total += filesize(path)
    end
    total <= MAX_BUNDLE_BYTES || bundle_error("Bundle exceeds Zenodo's 50 GB record limit.")
    names == [MANIFEST] && bundle_error("Bundle contains only a checksum manifest.")
    return names
end

"""
    _snapshot(dir) -> Vector{BundleFile}

Hash every file in `dir`.
"""
function _snapshot(dir::AbstractString)
    map(_bundle_names(dir)) do name
        path = joinpath(dir, name)
        BundleFile(name, filesize(path), file_sha256(path), file_md5(path))
    end
end

"""
    build_bundle(dir; metadata) -> Bundle

Validate `metadata` (a dictionary, or the path of a JSON file) with
[`validate_metadata`](@ref), check that `dir` is a flat directory of safely
named regular files, and snapshot each file's size, SHA-256 and MD5. If a
`checksums.sha256` manifest is present it must already be correct.

The bundle is never modified by this package except by
[`write_checksums!`](@ref).
"""
function build_bundle(dir::AbstractString; metadata)
    input = metadata isa AbstractString ? read_json(metadata) : metadata
    input isa AbstractDict || invalid("metadata must be a dictionary or the path of a JSON object.")
    validated = validate_metadata(input)
    root = abspath(dir)
    bundle = Bundle(root, validated, _snapshot(root))
    any(f -> f.name == MANIFEST, bundle.files) && _check_manifest(bundle)
    return bundle
end

"""
    write_checksums!(bundle) -> Bundle

Write `checksums.sha256` (`sha256sum` format, sorted by name) covering every
other file in the bundle directory, and return a freshly built bundle that
includes the manifest. The manifest is uploaded with the other files.
"""
function write_checksums!(bundle::Bundle)
    names = filter(!=(MANIFEST), _bundle_names(bundle.dir))
    isempty(names) && bundle_error("Bundle has no files to checksum.")
    text = join(file_sha256(joinpath(bundle.dir, n)) * "  " * n * "\n" for n in names)
    path = joinpath(bundle.dir, MANIFEST)
    islink(path) && bundle_error("The checksum manifest must not be a symlink.")
    write(path, text)
    return Bundle(bundle.dir, bundle.metadata, _snapshot(bundle.dir))
end

"""
    _check_manifest(bundle) -> true

Check that `checksums.sha256` lists every other file exactly once with its
current SHA-256, and nothing else.
"""
function _check_manifest(bundle::Bundle)
    path = joinpath(bundle.dir, MANIFEST)
    isfile(path) && !islink(path) || bundle_error("Bundle has no checksums.sha256 manifest. Call write_checksums! first.")
    names = Set(filter(!=(MANIFEST), _bundle_names(bundle.dir)))
    seen = Set{String}()
    for line in eachline(path)
        m = match(r"^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]{0,199})$", line)
        isnothing(m) && bundle_error("checksums.sha256 has a malformed line.")
        hash, name = m.captures
        name in names && !(name in seen) || bundle_error("checksums.sha256 lists an unexpected or repeated file: $name")
        file_sha256(joinpath(bundle.dir, name)) == hash || bundle_error("Checksum mismatch for $name: the file changed.")
        push!(seen, name)
    end
    seen == names || bundle_error("checksums.sha256 does not cover every file: missing $(join(sort!(collect(setdiff(names, seen))), ", ")).")
    return true
end

"""
    verify_bundle(bundle) -> true

Verify that the bundle directory still matches the snapshot taken by
[`build_bundle`](@ref) (same names, sizes and hashes) and that its
`checksums.sha256` manifest exists and is correct. Throws a
[`DepositError`](@ref) with code `invalid_bundle` otherwise.
"""
function verify_bundle(bundle::Bundle)
    _check_manifest(bundle)
    _snapshot(bundle.dir) == bundle.files ||
        bundle_error("Bundle files changed since build_bundle. Rebuild the bundle; a journal stays bound to the original bytes.")
    return true
end

"""
    fingerprint(bundle) -> String

SHA-256 over the canonical JSON of the bundle's files and metadata. A journal
is bound to this value on its first deposit.
"""
fingerprint(bundle::Bundle) = bytes2hex(sha256(canonical_json(Dict(
    "metadata" => bundle.metadata,
    "files" => [Dict("name" => f.name, "size" => f.size, "sha256" => f.sha256) for f in bundle.files]))))

