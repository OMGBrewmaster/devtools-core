#!/bin/bash
# Post-install: report whether the workspace a container just mounted is
# actually usable. Image configuration is baked in at build time by
# Tools/devcontainer/build/setup.sh; this runs once per workspace, after the
# repository is mounted, and only inspects.
#
# Called from a consuming repository's devcontainer lifecycle — its
# postCreateCommand runs a one-line wrapper that delegates here:
#   bash /workspace/workshop/Tools/devcontainer/post_install.sh
#
# Nothing here names a mount point. The script locates itself and treats its own
# grandparent directory as the checkout, so a repository that mounts Workshop
# under a different name needs no edit, and so does a private wrapper that nests
# it. What it checks is the one thing a fresh container gets wrong: a recorded
# submodule that was never initialized, which is silent until a tool follows a
# link into an empty directory.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checkout_dir="$(cd "$script_dir/../.." && pwd)"
workspace="$(cd "$checkout_dir/.." && pwd)"

project_name="$(basename "$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null || echo "$workspace")")"

echo "=== Post-install ($project_name) ==="

# `git submodule status` prefixes an uninitialized entry with '-'. A repository
# with no submodules prints nothing, which is a pass, not a silence to worry at.
uninitialized="$(git -C "$workspace" submodule status 2>/dev/null | sed -n 's/^-//p')"

if [ -n "$uninitialized" ]; then
    echo ""
    echo "WARNING: this workspace records submodules that are not initialized:"
    printf '%s\n' "$uninitialized" | awk '{print "  " $2}'
    echo ""
    echo "Run:  git -C $workspace submodule update --init --recursive"
    echo ""
fi

echo "=== Post-install complete ==="
