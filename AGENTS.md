# AGENTS.md — Workshop

Workshop is the public home for shared agent skills, tooling, and documentation
standards. Read this when contributing here or using Workshop as a submodule;
the generated-mirror warning remains in force until the private cutover is made.

## Current source of truth

Workshop is generated from a reviewed public subset of a private upstream. Do
not submit direct code changes or pull requests yet: the next upstream publish
would overwrite them. Report issues here and follow the support policy in
[SUPPORT.md](SUPPORT.md); maintainers will route work through the current
source of truth until the cutover formally changes this policy.

## Working in a project that vendors Workshop

- Link selected skills from `workshop/.agents/skills/` into a project's
  `.agents/skills/`; `bash workshop/Tools/sync-skill-symlinks.sh .` maintains
  both the canonical surface and the Claude bridge.
- Read [docs/signal-hygiene.md](docs/signal-hygiene.md) and
  [docs/definition-of-done.md](docs/definition-of-done.md) before claiming a
  check or task complete.
- The repository's own public gates are declared in
  [docs/work/definition-of-done.md](docs/work/definition-of-done.md).

## Future direct contribution

The forthcoming cutover will replace this generated-repository warning with a
normal contribution workflow. [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md), [SUPPORT.md](SUPPORT.md), and
[CHANGELOG.md](CHANGELOG.md) already define the public policies that will apply
then; they do not authorize hand edits before the cutover.

## License

MIT — see [LICENSE](LICENSE).
