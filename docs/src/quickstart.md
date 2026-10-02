<!-- SPDX-License-Identifier: MPL-2.0 -->
# Quickstart

## 1. Get a sandbox token

Create a personal access token on <https://sandbox.zenodo.org> (account →
Applications) with the `deposit:write` and `deposit:actions` scopes. Then
either export it:

```sh
export ZENODO_SANDBOX_TOKEN=...   # production uses ZENODO_TOKEN
```

or add a line to `~/.netrc`, and make that file readable only by you (`chmod 600`):

```
machine sandbox.zenodo.org password ...
```

## 2. Describe the deposit

`metadata.json` uses Zenodo's deposition metadata fields:

```json
{
  "title": "Measurements for the 2026 field season",
  "upload_type": "dataset",
  "description": "Raw and cleaned measurements.",
  "creators": [{"name": "Doe, Jane", "orcid": "0000-0002-1825-0097"}],
  "license": "cc-by-4.0",
  "access_right": "open"
}
```

[`validate_metadata`](@ref) checks it before anything is sent.

## 3. Build, deposit, publish

```julia
using ZenodoDeposits

bundle = build_bundle("results/"; metadata = "metadata.json")
bundle = write_checksums!(bundle)      # adds SHA256SUMS to the bundle
verify_bundle(bundle)

journal = open_journal("results.zenodo-journal")
deposit!(journal, bundle)              # sandbox by default; safe to re-run
status(journal)["reserved_doi"]        # the DOI is reserved, not yet registered

doi = publish!(journal; confirm = true) # permanent
citation_cff(journal)                  # CITATION.cff text for the record
```

If a call is interrupted (crash, timeout, `Ctrl-C`), run it again with the
same journal. `deposit!` continues from the last recorded state. If a publish
request may have reached Zenodo without a reply, the journal is in
`:publish_uncertain`. In that state `publish!` and [`reconcile!`](@ref) only
read the deposition to learn what happened; they never send another publish.

## 4. Command line

```sh
bin/zenodo-deposit results/ --metadata metadata.json            # sandbox draft
bin/zenodo-deposit results/ --metadata metadata.json --publish  # asks first
bin/zenodo-deposit results/ --metadata metadata.json --production --publish --yes
```

Exit codes: `0` ok, `1` error, `2` usage, `3` outcome unknown (re-run to
reconcile).
