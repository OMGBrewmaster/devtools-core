# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

## Unreleased

- Workshop is now the hand-authored source of truth; public contributions use
  the pull-request workflow and private vulnerability reporting.
- `Tools/devcontainer/` publishes a project-neutral `install-packages.sh` and a
  mount-agnostic `post_install.sh`, so a consuming image can source its whole
  container layer from Workshop instead of keeping a private copy.

## Release policy

Tags and GitHub Releases are maintainer-initiated, immutable identifiers for
the exact checked commit. Continuous integration validates each pushed tag with
`make check`; Workshop makes no release-cadence or semantic-versioning
compatibility promise.
