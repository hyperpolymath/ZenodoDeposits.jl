# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

"""
    ZenodoDeposits

Reproducible, resumable Zenodo deposits and DOI minting.

The workflow has two phases:

1. [`deposit!`](@ref) creates a Zenodo draft with a reserved DOI, uploads every
   file of a validated [`Bundle`](@ref) and verifies the remote copy. It can be
   repeated after any interruption and never creates a second deposition.
2. [`publish!`](@ref) publishes the verified draft. Publication is
   irreversible, needs `confirm=true`, and is never sent twice.

Every state change goes through the pure [`transition`](@ref) table, which is
mirrored in the Agda proofs under `proofs/agda/`. Tokens are read only from the
environment (`ZENODO_SANDBOX_TOKEN` / `ZENODO_TOKEN`) or `~/.netrc`, and are
never written to journals or bundles.
"""
module ZenodoDeposits

using Dates, HTTP, JSON3, Logging, MD5, SHA

export Bundle, BundleFile, build_bundle, write_checksums!, verify_bundle, validate_metadata,
       Journal, open_journal, deposit!, publish!, reconcile!, recover!, status, journal_state,
       citation_cff, Client, DepositError, RemoteError, transition, TRANSITIONS

include("errors.jl")
include("storage.jl")
include("metadata.jl")
include("bundles.jl")
include("client.jl")
include("transitions.jl")
include("journal.jl")
include("cli.jl")

end # module ZenodoDeposits
