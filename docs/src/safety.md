<!-- SPDX-License-Identifier: MPL-2.0 -->
# Safety model

## The journal state machine

| state | meaning |
|:--|:--|
| `:empty` | nothing sent |
| `:create_uncertain` | a create request was sent and its outcome is unknown |
| `:draft` | a draft with a reserved DOI exists |
| `:uploaded` | every file uploaded and verified against the bundle |
| `:publish_uncertain` | a publish request was sent and its outcome is unknown |
| `:published` | terminal: the DOI is registered |

Each action has one of three outcomes. On `:ok` it succeeded. On `:rejected`
it definitely failed and the state is unchanged, so the action can be retried.
On `:ambiguous` (crash, timeout, 5xx) it may or may not have taken effect.

Before sending a create or publish request, the journal persists the state
for the ambiguous outcome (a write-ahead record). A crash at any point
therefore leaves an `*_uncertain` state on disk. From that state only reading
actions are permitted: [`recover!`](@ref) for a create, and
[`reconcile!`](@ref) or [`publish!`](@ref) for a publish. If a publish never
reached Zenodo, the journal stays in `:publish_uncertain`. That state is
deliberately sticky. To leave it, publish the draft on the Zenodo website and
call `reconcile!`.

## Proofs

`proofs/agda/ZenodoDeposits/Transitions.agda` is generated from
[`TRANSITIONS`](@ref) by `julia --project proofs/agda/generate.jl`, and the
test suite fails if the committed file is stale. In
`proofs/agda/ZenodoDeposits/Journal.agda`, checked with `--safe --without-K`
and no postulates:

- `at-most-one-publish`: no trace from any state contains two publish
  requests. The same holds for creates (`at-most-one-create`) and for minted
  DOIs (`at-most-one-mint`).
- `resume-never-republishes`: if a run up to some persisted state has sent a
  publish request, no continuation from that state sends another.
- `no-publish-after-publish-uncertain`, `no-publish-after-published`:
  resuming from either state never sends a publish request.
- `published-terminal`, `published-stays`, `published-silent`: `published`
  is never left and emits nothing.
- `write-ahead-create`, `write-ahead-publish`: the state persisted before a
  request is the model's ambiguous-outcome state.

These proofs cover the transition table, which is the abstract model. They do
not cover the HTTP code, the file system, or Zenodo itself. The tests exercise
those against a scripted fake of the Zenodo API, with crashes at every step.

## Credentials

- Tokens are read from `ZENODO_SANDBOX_TOKEN` (sandbox) or `ZENODO_TOKEN`
  (production), or from `~/.netrc` (`$NETRC`). A netrc file readable by group
  or others is refused.
- A token is held in a value that always prints as `[REDACTED]`. It is sent
  only to the selected Zenodo host and to that deposition's own file bucket.
- No response body or HTTP exception is carried in an error, because either
  could echo the credential.
- A 429 or 503 response is retried with bounded exponential backoff that
  honours `Retry-After`. A wait longer than the retry budget is reported, not
  slept.
- The API is pinned to the legacy deposition v1 endpoints
  (`/api/deposit/depositions`).
