#!/usr/bin/env bash
#
# sync-skill-symlinks.sh — regenerate a project's per-skill shared-skill symlinks
#
# Each OMG Brews project consumes the shared skills in devtools by symlinking
# them in. Historically that was a single directory-level symlink
# (.claude/skills -> ../devtools/.claude/skills), which makes it impossible to
# add a project-specific skill alongside the shared ones.
#
# This script creates (or refreshes) PER-SKILL symlinks, on TWO surfaces:
#
#   .agents/skills/<name> -> ../../devtools/.agents/skills/<name>   canonical
#   .claude/skills/<name> -> ../../.agents/skills/<name>            Claude Code bridge
#
# .agents/skills/ is the Agent Skills open standard's path, which every harness
# scans; .claude/skills/ is Claude Code's, and it chains through the canonical
# link rather than reaching into devtools a second time. Writing only the vendor
# surface is what left every non-Claude harness finding no shared skills at all,
# so both are written, always, and the canonical one is written first — the
# bridge points at it.
#
# Usage:
#   sync-skill-symlinks.sh [REPO_ROOT]
#
#   REPO_ROOT  Directory containing .claude/ (or .agents/) and devtools/
#              (default: cwd).
#
# Behaviour, applied to each surface independently:
#   - Converts a directory-level symlink into a real directory.
#   - Creates/refreshes one symlink per shared skill (idempotent).
#   - Leaves project-specific skills (real directories) untouched.
#   - On a name collision (a project skill named like a shared skill), keeps the
#     project skill, skips the shared link, and warns.
#   - Removes stale links that point at a shared-skill path but no longer
#     resolve — including links left over from the pre-2026-08 layout, whose
#     targets still read .../devtools/.claude/skills/<name>.
#   - Verifies every link it is responsible for resolves to a readable SKILL.md.
#
# Exit status: 0 on success (even with warnings), non-zero on a usage/layout
# error or an unresolvable link on either surface.

set -euo pipefail
shopt -s nullglob   # an empty skills dir must expand to nothing, not a literal '*'

REPO_ROOT="${1:-$PWD}"
SRC_DIR="$REPO_ROOT/devtools/.agents/skills"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$REPO_ROOT/.claude" ] || [ -d "$REPO_ROOT/.agents" ] \
  || err "no .claude/ or .agents/ under $REPO_ROOT"
[ -d "$SRC_DIR" ] || err "no shared skills at $SRC_DIR (is the devtools submodule initialized?)"

dangling=0

# sync_surface <skills-dir> <relative-target-prefix> <label>
sync_surface() {
  local skills_dir="$1" rel_prefix="$2" label="$3"
  local created=0 refreshed=0 collisions=0 removed=0
  local src name dst want target

  # 1. If the skills dir is a directory-level symlink, replace it with a real dir.
  if [ -L "$skills_dir" ]; then
    rm "$skills_dir"
    echo "converted directory-level symlink to a real directory: $skills_dir"
  fi
  mkdir -p "$skills_dir"

  # 2. Create / refresh one symlink per shared skill.
  for src in "$SRC_DIR"/*/; do
    name="$(basename "$src")"
    dst="$skills_dir/$name"
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
      echo "warning: project-specific skill '$name' shadows the shared skill of the same name — keeping the project skill, skipping the shared link" >&2
      collisions=$((collisions + 1))
      continue
    fi
    want="$rel_prefix/$name"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$want" ]; then
      refreshed=$((refreshed + 1))
    else
      ln -sfn "$want" "$dst"
      created=$((created + 1))
    fi
  done

  # 3. Remove stale links: symlinks aimed at a shared-skill path that no longer
  #    resolve. Both target shapes are swept — the canonical/bridge ones this
  #    script writes today, and the pre-move ../../devtools/.claude/skills/<name>
  #    that a repo synced by an older devtools still carries. A repo bumped past
  #    the move but never re-synced would otherwise keep a link that resolves
  #    only by accident of the compatibility bridge.
  for dst in "$skills_dir"/*; do
    [ -L "$dst" ] || continue
    target="$(readlink "$dst")"
    case "$target" in
      */devtools/.claude/skills/*|*/.agents/skills/*)
        if [ ! -e "$dst" ]; then rm "$dst"; removed=$((removed + 1)); fi
        ;;
    esac
  done

  # 4. Verify every shared link actually resolves to a real skill.
  #    A dangling symlink is created without error and looks fine under `ls` — it
  #    only fails at skill-invocation time as "Unknown skill". Check with test -e,
  #    never a visual scan. (Catches an uninitialized devtools submodule or any
  #    layout where the relative prefix would be wrong.)
  for src in "$SRC_DIR"/*/; do
    name="$(basename "$src")"
    dst="$skills_dir/$name"
    [ -L "$dst" ] || continue                       # skipped as a collision; not ours to verify
    if [ ! -e "$dst" ] || [ ! -r "$dst/SKILL.md" ]; then
      echo "error: link does not resolve to a readable skill: $dst -> $(readlink "$dst")" >&2
      dangling=$((dangling + 1))
    fi
  done

  # 5. Report this surface.
  echo "synced $skills_dir ($label): ${created} linked, ${refreshed} already current, ${removed} stale removed, ${collisions} collision(s)"
  [ "$collisions" -gt 0 ] && echo "  (review collisions above; rename the project skill if it should not shadow a shared one)"
  return 0
}

# Canonical first: the bridge's links point into it, so syncing the bridge
# against a not-yet-written .agents/skills would report every link dangling.
sync_surface "$REPO_ROOT/.agents/skills" "../../devtools/.agents/skills" "canonical"
sync_surface "$REPO_ROOT/.claude/skills" "../../.agents/skills" "Claude Code bridge"

if [ "$dangling" -gt 0 ]; then
  echo "FAILED: ${dangling} shared skill link(s) do not resolve — see errors above" >&2
  exit 1
fi
exit 0
