# AGENTS.md — Workshop

Workshop is the public home for shared agent skills, tooling, and documentation
standards. Read this when contributing here or using Workshop as a submodule.

## Current source of truth

Workshop is the hand-authored source of truth. Contributions follow
[CONTRIBUTING.md](CONTRIBUTING.md), issues follow [SUPPORT.md](SUPPORT.md),
and every change must satisfy the public gates in
[docs/work/definition-of-done.md](docs/work/definition-of-done.md).

## Working in a project that vendors Workshop

- Link selected skills from `workshop/.agents/skills/` into a project's
  `.agents/skills/`; `bash workshop/Tools/sync-skill-symlinks.sh .` maintains
  both the canonical surface and the Claude bridge.
- Read [docs/signal-hygiene.md](docs/signal-hygiene.md) and
  [docs/definition-of-done.md](docs/definition-of-done.md) before claiming a
  check or task complete.
- The repository's own public gates are declared in
  [docs/work/definition-of-done.md](docs/work/definition-of-done.md).

## License

MIT — see [LICENSE](LICENSE).
