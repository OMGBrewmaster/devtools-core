#!/usr/bin/env bash
# Regression coverage for Workshop's standalone Markdown-link gate.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Tools/check-markdown-links.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$work/good/docs" "$work/good/assets"
printf 'ok\n' > "$work/good/docs/guide.md"
printf 'image\n' > "$work/good/assets/logo.png"
# shellcheck disable=SC2016 # Markdown backticks and parentheses are literal fixture bytes.
printf '[guide](docs/guide.md) ![logo](assets/logo.png) [ref]: docs/guide.md\n`[ignored](missing.md)`\n```text\n[ignored](missing.md)\n```\n[web](https://example.com) [part](#here)\n' > "$work/good/README.md"
git -C "$work/good" init -q
git -C "$work/good" add -A
git -C "$work/good" -c user.name=test -c user.email=test@example.com commit -qm fixture
bash "$check" "$work/good" > "$work/good.log" 2>&1 || { cat "$work/good.log"; fail "valid links failed"; }
echo "ok 1 - relative links pass; code, URIs, and fragments are ignored"

printf '[gone](docs/missing.md)\n' > "$work/good/broken.md"
git -C "$work/good" add broken.md
git -C "$work/good" -c user.name=test -c user.email=test@example.com commit -qm broken
if bash "$check" "$work/good" > "$work/broken.log" 2>&1; then
  fail "broken relative link passed"
fi
grep -q 'broken.md -> docs/missing.md' "$work/broken.log" || { cat "$work/broken.log"; fail "broken link was not named"; }
echo "ok 2 - broken relative links fail by source and target"

echo "all markdown-link tests passed"
