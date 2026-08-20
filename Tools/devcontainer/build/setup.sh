#!/bin/bash
# Single source of truth for devcontainer configuration.
# Called during Docker build (COPY the directory + RUN this file). No runtime deps.
#
# This file is HARNESS-NEUTRAL. It does the container setup every project needs
# regardless of which coding assistant runs in it — git LFS filters, git config, the gh
# credential helper, the volume-workspace bootstrap hook — and then hands off to each
# harness-*.sh beside it. Anything specific to one coding harness belongs in that
# harness's file, never here.
#
# The split replaced a single Claude-only script. The README's "Harness scope:
# Claude-first by choice" section named the trigger for splitting it — a second harness
# self-hosting in these containers — and that trigger fired: Oh My Pi and Codex both
# run here now.
#
# Configures:
#   - Git LFS filter config (global, since no .git dir at build time)
#   - Git config (autocrlf, safe.directory, user identity, bind-mount stat handling)
#   - gh as git's credential helper for github.com HTTPS
#   - Volume-workspace auto-populate shell hook
#   - Every harness-*.sh in this directory (Claude Code, Oh My Pi, Codex)

set -euo pipefail

SETUP_SELF="${BASH_SOURCE[0]:?setup.sh must be run as a file (bash setup.sh), not piped on stdin: the harness lookup needs its own path}"
BUILD_DIR="$(cd "$(dirname "$SETUP_SELF")" && pwd)"

# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"

echo "=== Devcontainer setup ==="

# 1. Git LFS filter config (equivalent to `git lfs install --global`)
git config --global filter.lfs.clean "git-lfs clean -- %f"
git config --global filter.lfs.smudge "git-lfs smudge -- %f"
git config --global filter.lfs.process "git-lfs filter-process"
git config --global filter.lfs.required true
echo "  Git LFS filters registered"

# 2. Git config. Contributor-neutral: the git identity is deliberately NOT set
# here — this kit ships in the public Workshop mirror, and a hard-coded
# maintainer identity is exactly the kind of personal default that must not.
# The private directory-copy build applies identity from the overlay sibling
# (section 2b); a public build stays anonymous and the user's first commit
# prompts for identity, which is the correct behavior for a contributor.
git config --global core.autocrlf input
git config --global safe.directory /workspace

# The macOS bind-mount filesystem returns stat metadata git does not trust, so a
# clean file reads as modified and a rebase pick dies with "Your local changes to
# the following files would be overwritten by merge" on a tree where both
# `git status --porcelain` and `git diff-files --name-only` print nothing.
# checkStat=minimal narrows the comparison to mtime and size, dropping ctime,
# inode, uid, gid and dev; trustctime=false drops ctime alone.
# Measured 2026-08-07 by the same fixture run seconds apart on both filesystems:
# on the bind mount (`fakeowner`) the phantom error, on overlay an honest
# `CONFLICT (content)`, and with these two settings the bind mount produced the
# honest conflict too. Set unconditionally rather than on detecting a bind mount:
# both are harmless on the volume-backed containers, which is cheaper than a
# detection branch that can be wrong.
git config --global core.checkStat minimal
git config --global core.trustctime false
echo "  Git config set"

# 2b. Optional private overlay. build/ is public — the mirror publishes it and
# a contributor's build must stay anonymous — so maintainer identity (and any
# other personal default) lives in a sibling directory that only the PRIVATE
# directory-copy build carries into the image. The private Dockerfile COPYs
# devtools/Tools/devcontainer/overlay to /tmp/devcontainer-overlay (and sets
# DEVCONTAINER_OVERLAY_DIR); a live re-run from a private checkout finds the
# same directory as ../overlay beside this file. A public build has neither,
# and skips the block: no overlay file, no identity.
overlay_dir="${DEVCONTAINER_OVERLAY_DIR:-$BUILD_DIR/../overlay}"
if [ -d "$overlay_dir" ]; then
  overlay_applied=0
  for overlay in "$overlay_dir"/*.sh; do
    [ -f "$overlay" ] || continue
    # shellcheck source=Tools/devcontainer/overlay/user-identity.sh
    # shellcheck disable=SC1090  # the overlay path is resolved at runtime
    # shellcheck disable=SC1091 # The optional private identity overlay is not public.
    source "$overlay"
    overlay_applied=1
    echo "  private overlay applied: $(basename "$overlay")"
  done
  [ "$overlay_applied" -eq 1 ] || echo "  overlay directory present but empty: $overlay_dir"
else
  echo "  no private overlay — contributor-neutral git identity"
fi

# 3. Wire gh in as git's credential helper for github.com HTTPS, so that
# `git fetch`/`clone` of private repos reuses the gh token. We set this
# directly rather than via `gh auth setup-git` because gh is installed by a
# devcontainer feature that layers on *after* this build-time script — gh is
# not on PATH yet here. The helper is only invoked later, at fetch time, by
# which point gh and its token both exist. (`!gh ...` is resolved via PATH.)
git config --global --replace-all 'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://gist.github.com.helper' '!gh auth git-credential'
echo "  gh credential helper wired for github.com"

# 4. Volume-workspace auto-populate on first interactive shell. Two reasons this
# hangs off the shell rather than devcontainer lifecycle hooks: Windsurf/Devin's
# dev-containers fork never runs postCreate/postStart at all, and even in stock
# clients those hooks run before the IDE's git credential forwarding exists. An
# interactive terminal is the one context guaranteed to have both credentials
# and a human watching. Inert unless the project's devcontainer.json sets
# WORKSPACE_REPO_URL in containerEnv; retries on every new shell until the
# workspace is populated.
# shellcheck disable=SC2016  # single quotes are the point: this text is written verbatim
# into the rc files and must expand when a shell starts, not while this script runs.
BOOTSTRAP_HOOK='[ -n "${WORKSPACE_REPO_URL:-}" ] && [ ! -e "${WORKSPACE_DIR:-/workspace}/.git/devcontainer-populate-done" ] && [ -x /usr/local/bin/workspace-bootstrap.sh ] && bash /usr/local/bin/workspace-bootstrap.sh create; true'
while IFS= read -r rcfile; do
    if [ -f "$rcfile" ] && grep -qF 'workspace-bootstrap.sh' "$rcfile"; then
        continue
    fi
    echo "$BOOTSTRAP_HOOK" >> "$rcfile"
done < <(harness_rcfiles)
echo "  workspace auto-populate shell hook installed"

# 5. Coding harnesses.
#
# The manifest is truncated here and appended to by each harness script, so it always
# describes THIS run rather than accumulating across re-runs — a harness file deleted
# from the kit disappears from the manifest on the next build instead of lingering as a
# claim the image no longer honours.
: > "$HARNESS_MANIFEST"

# Discovered by glob, never listed. A hard-coded list is the shape that made the
# previous single-harness kit expensive to extend: adding a harness would mean editing
# this file, the validator, and hq's drift bake. Globbing here — paired with the
# directory-digest entry in hq's drift bake — means a new harness-<name>.sh is picked
# up, validated, and drift-tracked by dropping in one file.
harness_count=0
for harness in "$BUILD_DIR"/harness-*.sh; do
    [ -e "$harness" ] || break   # nullglob is not set; an unmatched glob is literal
    echo "--- $(basename "$harness")"
    bash "$harness"
    harness_count=$((harness_count + 1))
done

# Zero harnesses is a broken build context, not a minimal one. Every consuming Dockerfile
# COPYs this whole directory, so an empty glob means the COPY delivered a partial tree —
# and a container that silently ships with no coding assistant is precisely the
# reports-success-while-doing-nothing failure signal-hygiene.md is about.
if [ "$harness_count" -eq 0 ]; then
    echo "ERROR: no harness-*.sh found beside setup.sh (looked in $BUILD_DIR)." >&2
    echo "       A Dockerfile must COPY the whole build/ directory, not setup.sh alone." >&2
    exit 1
fi

echo "  $harness_count harness(es) configured: $(tr '\n' ' ' < "$HARNESS_MANIFEST")"
echo "=== Devcontainer setup complete ==="
