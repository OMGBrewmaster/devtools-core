#!/usr/bin/env bash
#
# sync-skill-symlinks.sh — regenerate per-skill symlinks for a project's .claude/skills/
#
# Each OMG Brews project consumes the shared skills in devtools by
# symlinking them into .claude/skills/. Historically that was a single
# directory-level symlink (.claude/skills -> ../devtools/.claude/skills), which
# makes it impossible to add a project-specific skill alongside the shared ones.
#
# This script converts to (or refreshes) PER-SKILL symlinks: one symlink in
# .claude/skills/ per shared skill, leaving room for real project-specific skill
# directories beside them. Run it after adding a new shared skill upstream, or to
# convert a repo off the old directory-level symlink.
#
# Usage:
#   sync-skill-symlinks.sh [REPO_ROOT]
#
#   REPO_ROOT  Directory containing .claude/ and devtools/ (default: cwd).
#
# Assumptions (true for every OMG Brews project): the project's devtools
# submodule lives at REPO_ROOT/devtools and skills at REPO_ROOT/.claude/skills,
# so each per-skill link reads ../../devtools/.claude/skills/<name>.
#
# Behaviour:
#   - Converts a directory-level .claude/skills symlink into a real directory.
#   - Creates/refreshes one symlink per shared skill (idempotent).
#   - Leaves project-specific skills (real directories) untouched.
#   - On a name collision (a project skill named like a shared skill), keeps the
#     project skill, skips the shared link, and warns.
#   - Removes stale links that point into devtools but no longer resolve.
#
# Exit status: 0 on success (even with warnings), non-zero on a usage/layout error.

set -euo pipefail
shopt -s nullglob   # an empty skills dir must expand to nothing, not a literal '*'

REPO_ROOT="${1:-$PWD}"
SKILLS_DIR="$REPO_ROOT/.claude/skills"
SRC_DIR="$REPO_ROOT/devtools/.claude/skills"
REL_PREFIX="../../devtools/.claude/skills"   # from .claude/skills/<name>

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$REPO_ROOT/.claude" ] || err "no .claude/ under $REPO_ROOT"
[ -d "$SRC_DIR" ] || err "no shared skills at $SRC_DIR (is the devtools submodule initialized?)"

created=0 refreshed=0 collisions=0 removed=0

# 1. If .claude/skills is a directory-level symlink, replace it with a real dir.
if [ -L "$SKILLS_DIR" ]; then
  rm "$SKILLS_DIR"
  echo "converted directory-level symlink to a real directory: $SKILLS_DIR"
fi
mkdir -p "$SKILLS_DIR"

# 2. Create / refresh one symlink per shared skill.
for src in "$SRC_DIR"/*/; do
  name="$(basename "$src")"
  dst="$SKILLS_DIR/$name"
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    echo "warning: project-specific skill '$name' shadows the shared skill of the same name — keeping the project skill, skipping the shared link" >&2
    collisions=$((collisions + 1))
    continue
  fi
  want="$REL_PREFIX/$name"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$want" ]; then
    refreshed=$((refreshed + 1))
  else
    ln -sfn "$want" "$dst"
    created=$((created + 1))
  fi
done

# 3. Remove stale links: symlinks that point into devtools but no longer resolve.
for dst in "$SKILLS_DIR"/*; do
  [ -L "$dst" ] || continue
  target="$(readlink "$dst")"
  case "$target" in
    */devtools/.claude/skills/*)
      if [ ! -e "$dst" ]; then rm "$dst"; removed=$((removed + 1)); fi
      ;;
  esac
done

# 4. Verify every shared link actually resolves to a real skill.
#    A dangling symlink is created without error and looks fine under `ls` — it
#    only fails at skill-invocation time as "Unknown skill". Check with test -e,
#    never a visual scan. (Catches an uninitialized devtools submodule or any
#    layout where the relative prefix would be wrong.)
dangling=0
for src in "$SRC_DIR"/*/; do
  name="$(basename "$src")"
  dst="$SKILLS_DIR/$name"
  [ -L "$dst" ] || continue                       # skipped as a collision; not ours to verify
  if [ ! -e "$dst" ] || [ ! -r "$dst/SKILL.md" ]; then
    echo "error: link does not resolve to a readable skill: $dst -> $(readlink "$dst")" >&2
    dangling=$((dangling + 1))
  fi
done

# 5. Report.
echo "synced $SKILLS_DIR: ${created} linked, ${refreshed} already current, ${removed} stale removed, ${collisions} collision(s)"
[ "$collisions" -gt 0 ] && echo "  (review collisions above; rename the project skill if it should not shadow a shared one)"
if [ "$dangling" -gt 0 ]; then
  echo "FAILED: ${dangling} shared skill link(s) do not resolve — see errors above" >&2
  exit 1
fi
exit 0
