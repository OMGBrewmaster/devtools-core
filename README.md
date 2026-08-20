# Workshop

Workshop is the public distribution of shared agent skills, tooling, and
documentation standards. It is ready to be used and validated as a standalone
repository; until the source-of-truth cutover, its contents remain generated.

## Status during the cutover transition

The private upstream currently publishes this repository. Do not send a pull
request or edit files directly: a publish would overwrite that work. You may
open an issue using the templates here; [SUPPORT.md](SUPPORT.md) explains where
to ask for help. The cutover will make the normal workflow described in
[CONTRIBUTING.md](CONTRIBUTING.md) authoritative.

## Use in another project

Mount Workshop as a pinned submodule, usually at `workshop/`, then link the
skills a project needs:

```bash
git submodule add https://github.com/OMGBrewmaster/workshop.git workshop
bash workshop/Tools/sync-skill-symlinks.sh .
```

The sync command creates one link per shared skill on `.agents/skills/` and
the Claude-specific bridge beside it. The tool discovers the actual mount name,
so `workshop/` is a convention rather than a requirement.

## Checks and releases

Run `make check` from a standalone clone to execute Workshop's complete public
gate set. GitHub Actions runs that same command for pushes, pull requests, and
tags. Maintainers create milestone tags and GitHub Releases manually after the
check passes; tags are immutable and identify the exact release commit. There
is no promised release cadence or semantic-versioning compatibility contract.

See [CHANGELOG.md](CHANGELOG.md) for release notes and
[docs/work/definition-of-done.md](docs/work/definition-of-done.md) for the
local check contract.

## License

MIT — see [LICENSE](LICENSE).
