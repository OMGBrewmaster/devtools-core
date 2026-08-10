# AGENTS.md — devtools-core

What this repository is, how to use it from any AI coding harness, and what it deliberately does not contain. Read this if you found the repository on its own or are working in a project that mounts it as a submodule; the mirror's `README.md` covers the generated-repository mechanics, this file is the harness-facing orientation.

## What this is

The public publish channel for omgbrews-devtools (private): shared agent skills, documentation standards, and tooling for task management and documentation review, generated from the upstream repo on every change there and republished on a daily schedule so a publish that never ran cannot leave this copy behind indefinitely. Nothing here is edited by hand — anything committed directly is overwritten by the next publish (see `README.md`).

## How a project uses it

- **Vendor the skills** — mount the repo as a submodule and link each skill you want into `.agents/skills/`, the [Agent Skills](https://agentskills.io/specification) discovery path, one symlink per skill. Claude Code additionally needs a per-skill bridge in `.claude/skills/`; both surfaces follow the standard, [`docs/harness-agnostic-repos.md`](docs/harness-agnostic-repos.md).
- **Run the conformance gate** — `bash Tools/check-agent-surfaces.sh <repo-root>` asserts checks 1–9 of the harness-agnostic standard against your own repo root (the argument is required; a default would audit the wrong tree).
- **Read the standards** — `docs/signal-hygiene.md` and `docs/definition-of-done.md` are the standing-rule pair the skills enforce, and `docs/harness-agnostic-repos.md` is the conformance standard itself.

## What it deliberately lacks

- **No instruction files of its own beyond this one.** The upstream repo's `AGENTS.md`/`CLAUDE.md` describe contributing *to devtools* and stay unpublished; this file is what a consumer of the mirror needs.
- **No `CLAUDE.md` bridge** — the mirror has no Claude-specific content, and the standard forbids a bridge that only redirects.
- **No task documents, no kaizen journal** — those live per project, not in shared tooling.

## License

MIT — see [`LICENSE`](LICENSE).
