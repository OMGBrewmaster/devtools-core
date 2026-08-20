#!/usr/bin/env bash
# Check relative Markdown file and image links in a standalone repository.
#
# URI targets, fragments, and links in fenced or inline code are deliberately
# outside this small public gate. Symlink sources are skipped and named: their
# apparent location can differ from the document a reader actually opens.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: bash Tools/check-markdown-links.sh <repo-root>" >&2; exit 2; }
root="$(cd "$1" && pwd)"
git -C "$root" rev-parse --git-dir > /dev/null 2>&1 \
  || { echo "$root is not a git repository — tracked Markdown files are the check's scope" >&2; exit 2; }
failures=0
skipped=0

check_target() {
  local source="$1" target="$2" path
  target="${target%%#*}"
  target="${target%%\?*}"
  case "$target" in
    ''|/*|*://*|mailto:*|tel:*) return 0 ;;
  esac
  path="$(dirname "$source")/$target"
  if [ ! -e "$path" ]; then
    printf 'broken Markdown link: %s -> %s\n' "${source#"$root"/}" "$target" >&2
    failures=$((failures + 1))
  fi
}

while IFS= read -r -d '' source; do
  source="$root/$source"
  if [ -L "$source" ]; then
    printf 'skipped symlink Markdown source: %s\n' "${source#"$root"/}"
    skipped=$((skipped + 1))
    continue
  fi
  while IFS=$'\t' read -r _ target; do
    [ -n "$target" ] || continue
    check_target "$source" "$target"
  done < <(
    awk '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      {
        line = $0
        gsub(/`[^`]*`/, "", line)
        rest = line
        while (match(rest, /!?\[[^]]*\]\([^)]*\)/)) {
          token = substr(rest, RSTART, RLENGTH)
          sub(/^!?\[[^]]*\]\([[:space:]]*/, "", token)
          sub(/[[:space:]]*\)$/, "", token)
          sub(/^</, "", token); sub(/>$/, "", token)
          print "inline\t" token
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (match(line, /^[[:space:]]*\[[^]]+\]:[[:space:]]*[^[:space:]]+/)) {
          token = line
          sub(/^[[:space:]]*\[[^]]+\]:[[:space:]]*/, "", token)
          sub(/[[:space:]].*$/, "", token)
          sub(/^</, "", token); sub(/>$/, "", token)
          print "reference\t" token
        }
      }
    ' "$source"
  )
done < <(git -C "$root" ls-files -z -- '*.md')

[ "$failures" -eq 0 ] || exit 1
echo "Markdown links valid; $skipped symlink source(s) skipped"
