<!-- SPDX-License-Identifier: MPL-2.0 -->
# API

## Bundles

```@docs
Bundle
BundleFile
build_bundle
write_checksums!
verify_bundle
validate_metadata
```

## Journal

```@docs
Journal
open_journal
deposit!
publish!
reconcile!
recover!
status
journal_state
citation_cff
```

## Client and errors

```@docs
Client
DepositError
RemoteError
```

## State machine

```@docs
transition
TRANSITIONS
```
