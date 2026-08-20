#!/usr/bin/env bash
# Tests for Tools/sync-skill-symlinks.sh.
#
# The script's contract, asserted here:
#   1. writes BOTH surfaces — .agents/skills/<n> -> ../../devtools/.agents/skills/<n>
#      (canonical) and .claude/skills/<n> -> ../../.agents/skills/<n> (bridge) —
#      each resolving to a readable SKILL.md;
#   2. is idempotent — a second run refreshes, creating nothing, on both;
#   3. leaves project-specific skills (real directories) untouched, and on a
#      name collision keeps the project skill and warns — per surface;
#   4. removes stale links that no longer resolve, in the current target shape
#      AND in the pre-2026-08 .../devtools/.claude/skills/<n> shape;
#   5. converts a legacy directory-level .claude/skills symlink;
#   6. fails loudly when a link would not resolve to a readable skill, and on
#      a repo with neither .claude/ nor .agents/ (the wrong-directory guard).
#   7. discovers the devtools mount whatever it is named — the fixture above is
#      named devtools/, so a mount under any other name (workshop/ for the
#      mirror consumer, its pre-rename placeholder before 2026-08) must resolve
#      the same way, with both link targets naming THAT directory. Fails against
#      the pre-discovery script, whose SRC_DIR was the hardcoded devtools/ literal.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$DEVTOOLS_ROOT/Tools/sync-skill-symlinks.sh"
MOUNT_NAME="$(basename "$DEVTOOLS_ROOT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

make_skill() { # <dir>
  mkdir -p "$1"
  echo "# a skill" > "$1/SKILL.md"
}

# Fixture: a project with two shared skills in the checkout that owns this test.
# The public candidate's directory name is not necessarily `devtools`, so a
# fixture that hard-codes that name tests the fixture rather than the tool.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude"
make_skill "$PROJ/$MOUNT_NAME/.agents/skills/alpha"
make_skill "$PROJ/$MOUNT_NAME/.agents/skills/beta"

# --- 1. fresh run links every shared skill, on both surfaces ----------------
out="$(bash "$SYNC" "$PROJ" 2>&1)" || fail "sync failed on a fresh project: $out"
[ "$(grep -c '2 linked' <<< "$out")" = 2 ] || fail "expected '2 linked' on both surfaces: $out"
echo "$out" | grep -q "canonical" || fail "canonical surface not reported: $out"
echo "$out" | grep -q "Claude Code bridge" || fail "bridge surface not reported: $out"

[ -L "$PROJ/.agents/skills/alpha" ] || fail "canonical alpha is not a symlink"
[ "$(readlink "$PROJ/.agents/skills/alpha")" = "../../$MOUNT_NAME/.agents/skills/alpha" ] \
  || fail "canonical alpha points at $(readlink "$PROJ/.agents/skills/alpha")"
[ -L "$PROJ/.claude/skills/alpha" ] || fail "bridge alpha is not a symlink"
[ "$(readlink "$PROJ/.claude/skills/alpha")" = "../../.agents/skills/alpha" ] \
  || fail "bridge alpha points at $(readlink "$PROJ/.claude/skills/alpha")"

# Both surfaces must resolve all the way through to the file, not merely exist.
[ -r "$PROJ/.agents/skills/beta/SKILL.md" ] || fail "beta unreadable through the canonical link"
[ -r "$PROJ/.claude/skills/beta/SKILL.md" ] || fail "beta unreadable through the bridge (two hops)"
echo "ok 1 - links every shared skill on both surfaces"

# --- 2. idempotent ----------------------------------------------------------
out="$(bash "$SYNC" "$PROJ" 2>&1)" || fail "second run failed: $out"
[ "$(grep -c '0 linked, 2 already current' <<< "$out")" = 2 ] \
  || fail "second run not idempotent on both surfaces: $out"
echo "ok 2 - idempotent"

# --- 3. project skills kept; collisions warn -------------------------------
make_skill "$PROJ/.claude/skills/local-only"
rm "$PROJ/.claude/skills/alpha"
make_skill "$PROJ/.claude/skills/alpha"   # real dir shadowing the shared skill
out="$(bash "$SYNC" "$PROJ" 2>&1)" || fail "sync failed with a collision present: $out"
echo "$out" | grep -q "collision" || fail "collision not warned: $out"
if [ ! -d "$PROJ/.claude/skills/alpha" ] || [ -L "$PROJ/.claude/skills/alpha" ]; then
  fail "project skill 'alpha' was replaced by a link"
fi
if [ ! -d "$PROJ/.claude/skills/local-only" ] || [ -L "$PROJ/.claude/skills/local-only" ]; then
  fail "project-specific skill 'local-only' was touched"
fi
# The other surface is independent: a shadow on the bridge must not remove the
# canonical link, or the shared skill vanishes for every non-Claude harness.
[ -L "$PROJ/.agents/skills/alpha" ] || fail "canonical alpha lost to a bridge-side collision"
echo "ok 3 - project skills kept, collision warned, surfaces independent"

# --- 4. stale links removed, in both target shapes --------------------------
ln -s "../../.agents/skills/gone" "$PROJ/.claude/skills/gone"
ln -s "../../devtools/.claude/skills/legacy" "$PROJ/.claude/skills/legacy"   # pre-move shape
out="$(bash "$SYNC" "$PROJ" 2>&1)" || fail "sync failed with stale links present: $out"
echo "$out" | grep -q "2 stale removed" || fail "stale links not reported removed: $out"
for stale in gone legacy; do
  if [ -e "$PROJ/.claude/skills/$stale" ] || [ -L "$PROJ/.claude/skills/$stale" ]; then
    fail "stale link '$stale' still present"
  fi
done
echo "ok 4 - stale links removed in both target shapes"

# --- 5. legacy directory-level symlink converted ----------------------------
PROJ2="$TMP/proj2"
mkdir -p "$PROJ2/.claude"
make_skill "$PROJ2/$MOUNT_NAME/.agents/skills/alpha"
ln -s "../$MOUNT_NAME/.claude/skills" "$PROJ2/.claude/skills"
out="$(bash "$SYNC" "$PROJ2" 2>&1)" || fail "sync failed on a legacy layout: $out"
echo "$out" | grep -q "converted directory-level symlink" || fail "conversion not reported: $out"
if [ ! -d "$PROJ2/.claude/skills" ] || [ -L "$PROJ2/.claude/skills" ]; then
  fail "skills dir still a symlink"
fi
[ -L "$PROJ2/.claude/skills/alpha" ] || fail "per-skill bridge link missing after conversion"
[ -L "$PROJ2/.agents/skills/alpha" ] || fail "canonical link missing after conversion"
echo "ok 5 - legacy layout converted"

# --- 6. loud failures -------------------------------------------------------
# A shared skill directory without a readable SKILL.md must fail the run.
PROJ3="$TMP/proj3"
mkdir -p "$PROJ3/.claude" "$PROJ3/$MOUNT_NAME/.agents/skills/gamma"   # no SKILL.md
if out="$(bash "$SYNC" "$PROJ3" 2>&1)"; then
  fail "sync passed although gamma has no SKILL.md: $out"
fi
echo "$out" | grep -q "FAILED" || fail "unresolvable skill not reported loudly: $out"
# Both surfaces are checked, so both report the same skill.
[ "$(grep -c 'does not resolve to a readable skill' <<< "$out")" = 2 ] \
  || fail "the dangling link was not reported on both surfaces: $out"
# Neither .claude/ nor .agents/: the wrong-directory guard.
PROJ4="$TMP/proj4"
make_skill "$PROJ4/$MOUNT_NAME/.agents/skills/alpha"
if out="$(bash "$SYNC" "$PROJ4" 2>&1)"; then
  fail "sync passed on a repo with no .claude/ or .agents/: $out"
fi
echo "$out" | grep -q "no .claude/" || fail "missing skills root not reported: $out"
echo "ok 6 - failure paths are loud"

# --- 7. the mount is discovered, whatever it is named -----------------------
# The script must be run FROM ITS OWN checkout inside the fixture's mount —
# self-location is the discovery mechanism, and an alternate mount name is only
# trustable when the script ships inside that mount (the pia-maker shape:
# `bash workshop/Tools/sync-skill-symlinks.sh <repo-root>`; the mirror consumer
# mounted the public mirror at that name after the 2026-08 rename from the
# placeholder).
PROJ5="$TMP/proj5"
mkdir -p "$PROJ5/.claude" "$PROJ5/workshop/Tools"
make_skill "$PROJ5/workshop/.agents/skills/alpha"
make_skill "$PROJ5/workshop/.agents/skills/beta"
cp "$SYNC" "$PROJ5/workshop/Tools/sync-skill-symlinks.sh"
out="$(bash "$PROJ5/workshop/Tools/sync-skill-symlinks.sh" "$PROJ5" 2>&1)" \
  || fail "sync failed for a workshop mount: $out"
[ "$(grep -c '2 linked' <<< "$out")" = 2 ] \
  || fail "expected '2 linked' on both surfaces for workshop: $out"
[ "$(readlink "$PROJ5/.agents/skills/alpha")" = "../../workshop/.agents/skills/alpha" ] \
  || fail "canonical alpha does not name the discovered mount: $(readlink "$PROJ5/.agents/skills/alpha")"
[ "$(readlink "$PROJ5/.claude/skills/alpha")" = "../../.agents/skills/alpha" ] \
  || fail "bridge alpha does not chain through the canonical surface: $(readlink "$PROJ5/.claude/skills/alpha")"
[ -r "$PROJ5/.agents/skills/beta/SKILL.md" ] || fail "beta unreadable through the workshop canonical link"
[ -r "$PROJ5/.claude/skills/beta/SKILL.md" ] || fail "beta unreadable through the workshop bridge"
echo "ok 7 - alternate mount name (workshop) discovered; fixture mount derived from the checkout"
