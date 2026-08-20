# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

## Unreleased

- Workshop is now the hand-authored source of truth; public contributions use
  the pull-request workflow and private vulnerability reporting.

## Release policy

Tags and GitHub Releases are maintainer-initiated, immutable identifiers for
the exact checked commit. Continuous integration validates each pushed tag with
`make check`; Workshop makes no release-cadence or semantic-versioning
compatibility promise.
