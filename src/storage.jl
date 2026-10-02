# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Private, atomic, locked storage for journal state. Never store secrets here.

"""
    canonical_json(x) -> String

Serialise `x` as JSON with object keys sorted, so equal values always produce
identical bytes. Supports dictionaries, vectors, strings, numbers, booleans,
symbols and `nothing`.
"""
function canonical_json(x)
    io = IOBuffer()
    _canonical!(io, x)
    return String(take!(io))
end

"""
    _canonical!(io, x)

Write the canonical JSON form of `x` to `io` (see [`canonical_json`](@ref)).
"""
function _canonical!(io::IO, x::AbstractDict)
    print(io, '{')
    for (i, key) in enumerate(sort!([string(k) for k in keys(x)]))
        i > 1 && print(io, ',')
        JSON3.write(io, key)
        print(io, ':')
        value = haskey(x, key) ? x[key] : x[Symbol(key)]
        _canonical!(io, value)
    end
    print(io, '}')
end
function _canonical!(io::IO, x::Union{AbstractVector,Tuple})
    print(io, '[')
    for (i, value) in enumerate(x)
        i > 1 && print(io, ',')
        _canonical!(io, value)
    end
    print(io, ']')
end
_canonical!(io::IO, x::Symbol) = JSON3.write(io, String(x))
_canonical!(io::IO, x::Union{AbstractString,Real,Nothing}) = JSON3.write(io, x)
_canonical!(::IO, x) = throw(ArgumentError("canonical_json: unsupported value of type $(typeof(x))"))

"""
    file_sha256(path) -> String

Lower-case hexadecimal SHA-256 of a file, read in a streaming fashion.
"""
file_sha256(path::AbstractString) = open(io -> bytes2hex(sha256(io)), path)

"""
    file_md5(path) -> String

Lower-case hexadecimal MD5 of a file. Zenodo reports MD5 checksums; it is used
for protocol integrity only, never as a provenance identity.
"""
file_md5(path::AbstractString) = open(io -> bytes2hex(md5(io)), path)

"""
    read_json(path) -> Dict{String,Any}

Read a JSON object from `path`.
"""
read_json(path::AbstractString) = JSON3.read(read(path, String), Dict{String,Any})

"""
    private_dir(path) -> path

Create `path` (mode 0700) if needed and refuse it if it is a symlink.
"""
function private_dir(path::AbstractString)
    islink(path) && fail("unsafe_storage", "Journal storage must not be a symlink: $path")
    mkpath(path; mode=0o700)
    chmod(path, 0o700)
    return path
end

const LOCK_EX = Cint(2)
const LOCK_NB = Cint(4)
const LOCK_UN = Cint(8)

"""
    with_lock(f, directory)

Run `f()` while holding an exclusive, non-blocking `flock` on
`directory/.lock`. A second holder fails at once with code `journal_busy`.
Kernel locks are released when the process dies, so they cannot go stale
during a slow upload. Only Unix filesystems (including WSL2) are supported.
"""
function with_lock(f::Function, directory::AbstractString)
    Sys.isunix() || fail("unsupported_storage", "Journals need a Unix filesystem with flock support (including WSL2).")
    private_dir(directory)
    path = joinpath(directory, ".lock")
    islink(path) && fail("unsafe_storage", "The journal lock must not be a symlink.")
    open(path, "a+") do io
        chmod(path, 0o600)
        acquired = ccall(:flock, Cint, (Cint, Cint), fd(io), LOCK_EX | LOCK_NB) == 0
        acquired || fail("journal_busy", "Another operation holds this journal. Wait for it to finish, then retry.")
        try
            return f()
        finally
            ccall(:flock, Cint, (Cint, Cint), fd(io), LOCK_UN)
        end
    end
end

"""
    atomic_write(path, content) -> path

Replace `path` with `content` atomically: write a private temporary file,
`fsync` it, `rename` it over the target and `fsync` the directory. Readers
see either the old or the new version, never a partial file.
"""
function atomic_write(path::AbstractString, content::AbstractString)
    directory = dirname(abspath(path))
    private_dir(directory)
    islink(path) && fail("unsafe_storage", "Journal files must not be symlinks.")
    tmp, io = mktemp(directory; cleanup=false)
    try
        chmod(tmp, 0o600)
        write(io, content)
        flush(io)
        ccall(:fsync, Cint, (Cint,), fd(io)) == 0 || error("could not fsync journal file")
        close(io)
        Base.Filesystem.rename(tmp, path)
        dirfd = ccall(:open, Cint, (Cstring, Cint), directory, 0)
        dirfd >= 0 || error("could not open journal directory")
        try
            ccall(:fsync, Cint, (Cint,), dirfd) == 0 || error("could not fsync journal directory")
        finally
            ccall(:close, Cint, (Cint,), dirfd)
        end
    finally
        isopen(io) && close(io)
        isfile(tmp) && rm(tmp)
    end
    return path
end

"""
    atomic_json(path, value) -> path

[`atomic_write`](@ref) the canonical JSON form of `value`, newline-terminated.
"""
atomic_json(path::AbstractString, value) = atomic_write(path, canonical_json(value) * "\n")
