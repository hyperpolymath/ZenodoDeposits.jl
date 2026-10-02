#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Typecheck the ZenodoDeposits Agda proofs without touching ~/.agda.
# Usage: proofs/agda/check.sh
# Env:   AGDA (default: agda), AGDA_STDLIB (default: /usr/share/agda-stdlib)
set -euo pipefail

# Print an error and exit non-zero.
die() {
  echo "check.sh: $*" >&2
  exit 1
}

# Write a project-local Agda libraries file naming the stdlib and this library.
write_libraries() {
  local here="$1" stdlib="$2"
  [ -f "$stdlib/standard-library.agda-lib" ] || die "no standard-library.agda-lib in $stdlib"
  printf '%s\n%s\n' "$stdlib/standard-library.agda-lib" "$here/zenodo-deposits.agda-lib" > "$here/libraries"
}

# Typecheck Journal.agda (which imports the generated Transitions.agda) from a clean build.
main() {
  local here agda stdlib
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  agda="${AGDA:-agda}"
  stdlib="${AGDA_STDLIB:-/usr/share/agda-stdlib}"
  command -v "$agda" >/dev/null || die "agda not found (set AGDA)"
  write_libraries "$here" "$stdlib"
  "$agda" --version
  rm -rf "$here/_build"
  cd "$here"
  "$agda" --library-file="$here/libraries" --no-default-libraries ZenodoDeposits/Journal.agda
  ! grep -RIn 'postulate' --include='*.agda' "$here/ZenodoDeposits" || die "postulate found"
  echo "check.sh: ZenodoDeposits.Journal typechecks (--safe --without-K, no postulates)"
}

main "$@"
