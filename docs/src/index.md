<!-- SPDX-License-Identifier: MPL-2.0 -->
# ZenodoDeposits.jl

Reproducible, resumable Zenodo deposits and DOI minting from Julia.

A deposit happens in two phases:

1. [`deposit!`](@ref) creates a Zenodo draft with a reserved DOI, uploads every
   file of a validated [`Bundle`](@ref) and checks the remote copy against the
   local checksums. It can be re-run after any interruption and never creates a
   second deposition.
2. [`publish!`](@ref) publishes the checked draft. Publication is permanent, so
   it needs `confirm=true`, and the publish request is never sent twice.

Progress is kept in a journal directory. Every state change goes through one
pure transition table, [`TRANSITIONS`](@ref). The Agda proofs in
`proofs/agda/` are generated from that table and show three things: no run
sends two publish requests, resuming never sends a publish again, and
`published` is terminal. See [Safety model](@ref).

Tokens come only from `ZENODO_SANDBOX_TOKEN` / `ZENODO_TOKEN` or `~/.netrc`.
They are never written to a journal or bundle, and they are redacted from
`show` output and error messages. The sandbox is the default; production
needs an explicit `env=:production`.

## Installation

The package is not registered. Install it from the repository:

```julia
using Pkg
Pkg.add(url = "https://github.com/hyperpolymath/ZenodoDeposits.jl")
```

Continue with the [Quickstart](@ref).
