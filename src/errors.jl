# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

"""
    DepositError(code, message)

A local, sanitised failure: invalid metadata or bundle, a journal conflict, a
missing confirmation, or a remote state that does not match the journal.
`code` is a stable machine-readable string; `message` never contains a token.
"""
struct DepositError <: Exception
    code::String
    message::String
end

"""
    showerror(io, e::DepositError)

Print the sanitised message and its code.
"""
Base.showerror(io::IO, e::DepositError) = print(io, "DepositError(", e.code, "): ", e.message)

"""
    RemoteError(status, code, message, ambiguous, retry_after)

A sanitised Zenodo failure. No response body or underlying HTTP exception
crosses this boundary, because either could echo a credential.

- `status`: the HTTP status, or 503 for a transport failure.
- `ambiguous`: `true` when a non-idempotent request may have taken effect.
- `retry_after`: seconds Zenodo asked us to wait, when that exceeded the
  retry budget; `nothing` otherwise.
"""
struct RemoteError <: Exception
    status::Int
    code::String
    message::String
    ambiguous::Bool
    retry_after::Union{Int,Nothing}
end

"""
    showerror(io, e::RemoteError)

Print the sanitised message, its code and status.
"""
Base.showerror(io::IO, e::RemoteError) =
    print(io, "RemoteError(", e.code, ", HTTP ", e.status, "): ", e.message)

"""
    fail(code, message)

Throw a [`DepositError`](@ref).
"""
fail(code::AbstractString, message::AbstractString) = throw(DepositError(String(code), String(message)))
