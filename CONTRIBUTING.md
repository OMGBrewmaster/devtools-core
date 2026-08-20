# Contributing to Workshop

This guide explains how to contribute once Workshop becomes the hand-authored
source of truth. Until the cutover completes, the repository is generated and
direct pull requests cannot be accepted.

## Before the cutover

Use the issue templates to report bugs or propose improvements. Do not prepare
a pull request against generated files: the upstream publisher owns the tree
and would overwrite it.

## After the cutover

Create a branch, make a focused change, and run `make check` in a standalone
clone before opening a pull request. Keep documentation links relative, retain
the standing rules imported by [CLAUDE.md](CLAUDE.md), and describe any user-
visible change in [CHANGELOG.md](CHANGELOG.md).

Maintainers review changes through the repository's normal checks. The stable
GitHub Actions context is `Workshop checks / check`; the cutover task activates
the ruleset that requires it and records the red-pull-request proof.

## Security reports

Do not open a public issue for a vulnerability. Follow
[SECURITY.md](SECURITY.md) instead.
