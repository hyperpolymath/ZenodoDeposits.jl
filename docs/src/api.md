<!-- SPDX-License-Identifier: MPL-2.0 -->
# API

## Module

```@docs
ZenodoDeposits
ZenodoDeposits.CLI
```

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
ZenodoDeposits.Secret
```

## State machine

```@docs
transition
TRANSITIONS
ZenodoDeposits.STATES
```
