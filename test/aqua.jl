# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

# Aqua.jl quality-gate testset — flagship-rubric dimension 2 (Static
# quality — Aqua). See docs/flagship-rubric.adoc.
#
# Aqua checks: method ambiguities, unbound type parameters, undefined
# exports, stale/missing deps, [compat] bounds (including `julia`), type
# piracy, and persistent tasks. The flagship bar is zero overrides — if
# Aqua flags something in your real package, fix the source (see
# Axiom.jl's test/aqua.jl for two worked examples of real fixes vs.
# exemptions) rather than reaching for `Aqua.test_all(Pkg; foo = false)`.

using Test
using Aqua
using ZenodoDeposits

@testset "Aqua quality gate" begin
    Aqua.test_all(ZenodoDeposits)
end
