#!/usr/bin/env bash
# Run every tests/test-*.sh in this directory. A test file passes iff it exits 0.
# Run from anywhere: bash tests/run-tests.sh. CI runs this on every push/PR
# (.github/workflows/ci.yml) alongside shellcheck.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failures=0
for t in test-*.sh; do
  echo "== $t"
  if bash "$t"; then
    echo "== $t: PASS"
  else
    echo "== $t: FAIL"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "$failures test file(s) failed" >&2
  exit 1
fi
echo "all test files passed"
