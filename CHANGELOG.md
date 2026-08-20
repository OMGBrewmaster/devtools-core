# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

## Unreleased

- The standalone contribution, support, security, release-validation, and
  quality-gate surfaces are prepared for the source-of-truth cutover.

## Release policy

Tags and GitHub Releases are maintainer-initiated, immutable identifiers for
the exact checked commit. Continuous integration validates each pushed tag with
`make check`; Workshop makes no release-cadence or semantic-versioning
compatibility promise.
