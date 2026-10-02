<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# You are in the hyperpolymath estate — orient before acting

If you are unsure what something is, **read the canon; do not guess** (guessing is how the fake `lith` monorepo got fabricated). Start here, then the files named below.

## Doctrine (the rules here)
1. **Holes before anything else** — fix soundness holes before features/perf/docs.
2. **Fixes first, on firm foundations** — ground-truth by running the tool, not trusting status docs.
3. **Fail loudly, seal soundly** — no silent green; seams (ABI/FFI) sealed & proven.
4. **Distrust the neural for exactness** — licences/invariants/equivalence belong to **PLASMA** (formal), not to an LLM. Your edits there are provisional + supervised.
5. **Squabble, don't bypass** — reach green by *satisfying* the gate, never by admin-override.
6. **No automated licence edits — ever** — manual, owner-only; third-party untouchable.
7. **No deletion by access-recency** — cold ≠ disposable.
8. **Wire first** — unwired is not done.
9. **Always sign** commits (`id_ed25519_signing`; verify `status:G`).
10. **Report faithfully — no overclaim** (the AFFIRMATION ethos).
11. **Stop-first** when an action is costly to undo or outward-facing.
12. **Boundaries are real** — respect IS / IS-NOT; never assimilate or rename across them.
13. **Equivalence as identity** — the estate's intellectual through-line.
14. **Solutions at source** — fix the canonical/upstream origin, never patch the downstream symptom; trace and respect every up- and down-stream before you act.

## The machine-readable substrate (read on arrival)

| File | Answers |
|---|---|
| `ZenodoDeposits.jl_chora.deed` | The repo deed (deed grammar, `deed_lint.py`). *Identity and lineage* (`identity`, `clade`, `lineage`, `status`); *concept authority* and ADRs (`meta`); *where it sits*, including what it is not (`ecosystem`); *may I act now?* (`agentic`); *meaning of operations* (`neurosym`); *how permitted actions run* (`playbook`); *where things are now* (`state`); *semantic authority and golden path* (`anchor`). |
| `.machine_readable/self-validating/*.k9.ncl` | *Validation*. Kennel (data) / Yard (pure eval) / Hunt (guarded exec). Run `.githooks/validate-k9.sh`. |

There are no `.a2ml` files. Do not create any.

## Canon pointers
- `hyperpolymath/standards` — the canon source. · `hyperpolymath/gv-clade-index` — the estate map (identity registry). · `hyperpolymath/manifesto` — this doctrine.
- **Before you invent, rename, or consolidate anything: STOP and check the map + IS-NOT.**

## Estate language policy (overridable per-repo in the deed's `agentic` section)
Deny: **Nix, Node/npm, TypeScript, Python, Go, AGPL**. (Guix, not Nix.)

---

# This repo: `ZenodoDeposits.jl`  ·  clade `rm-ZenodoDeposits.jl`

- **Identity** — `#u5"github.com/metadatastician/ZenodoDeposits.jl"` (repo deed); clade `rm` (secondary `gv`); born 2026-10-02; forge `metadatastician/ZenodoDeposits.jl`.
- **IS** — Generic Julia library for reproducible, resumable Zenodo deposits and DOI minting (deposition API v1).
- **IS-NOT** — MetaManifold-specific: no analysis store, web UI, DEED/Nickel or epistemic metadata (those stay in MetaManifold-WebUI) · a general Zenodo API client: it covers create, upload, verify, publish and read-back of one deposition per journal · registered in the General registry (not yet; an owner decision)
- **Where it sits** — pipeline position **library**; chain `rsr-julia-library-template-repo → ZenodoDeposits.jl → (MetaManifold-WebUI and other depositors)`; coordination = `standards`.
- **Constraints here** (deed `agentic`) — fail-closed; evidence-per-step; no-silent-skip; rerun-after-fix; release-claim-requires-hard-pass. Never: banned langs (above), secrets, state files in repo root, AGPL. Details: the `agentic` section of the repo deed.
- **Golden path** (deed `anchor`) — `just test && just quality` → Core tests pass; Quality gates pass; No unresolved critical security findings.
- **State** (deed `state`) — phase testing; maturity alpha; 80% complete; status active.

## Working on ZenodoDeposits.jl

- `src/transitions.jl` is the single source of the journal state machine.
  After changing it, run `julia --project proofs/agda/generate.jl` and
  `proofs/agda/check.sh`. The test suite fails if `Transitions.agda` is stale.
- Never add a code path that reads a token from anywhere other than
  `ZENODO_SANDBOX_TOKEN` / `ZENODO_TOKEN` / netrc, or that writes one to disk.
- The live sandbox test is opt-in (`ZENODO_LIVE_TEST=1`). A skip is not a pass.
