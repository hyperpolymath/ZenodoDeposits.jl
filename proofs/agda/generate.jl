# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Regenerate ZenodoDeposits/Transitions.agda from the Julia transition table:
#   julia --project proofs/agda/generate.jl
using ZenodoDeposits
path = joinpath(@__DIR__, "ZenodoDeposits", "Transitions.agda")
write(path, ZenodoDeposits.render_agda_transitions())
println("wrote ", path)
