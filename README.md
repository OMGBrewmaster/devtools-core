# devtools-core

Shared Claude Code skills, documentation standards, and tooling for task
management and documentation review. Read this if you have found the repo on its
own, or if you are working in a project that mounts it as a submodule.

## This repository is generated

The contents are published automatically from a private upstream repository on
every change there. **Nothing here is edited by hand**, and anything committed
directly is overwritten by the next publish.

- **No pull requests.** They cannot be merged — the next publish would discard
  them.
- **Issues and suggestions** are welcome; they are triaged upstream.
- Each commit message names the upstream commit it was generated from.

## What is here

| Path | What it is |
|------|-----------|
| `.claude/skills/task-*` | Claude Code skills for the task system — create, list, move, audit, reprioritize, finalize, pick the next one, implement it, report status, and run the autonomous queue |
| `.claude/skills/docs-audit` | Documentation audit skill — style compliance, navigation, accuracy |
| `.claude/skills/kaizen-resolve` | Closes out a continuous-improvement problem document once its flaw is verifiably gone |
| `Tools/sync-skill-symlinks.sh` | Regenerates a project's per-skill `.claude/skills/` symlinks |
| `docs/signal-hygiene.md` | How to know a step actually happened — read exit codes, never suppress output |
| `docs/definition-of-done.md` | What "done" requires, and where each repo names its own gates |
| `docs/templates/` | Copy-paste-ready templates for architecture docs, feature docs, ADRs, and directory READMEs |

The task skills are repo-agnostic: they find the tasks directory themselves
(`docs/tasks/`, else `docs/planning/tasks/`) and turn on queue behaviour only
where a `queued/` bucket exists.

## Using it in a project

Mount it as a submodule and link the skills you want into `.claude/skills/`:

```bash
git submodule add https://github.com/OMGBrewmaster/devtools-core.git devtools-core
ln -s ../../devtools-core/.claude/skills/task-list .claude/skills/task-list
```

A consuming project pins the submodule at a specific commit and moves that
pointer when it chooses, so an upstream change never lands in a project without
someone asking for it.

Cloning a project that mounts it needs no credentials of any kind:

```bash
git clone --recurse-submodules <project-url>
# or, in an existing clone:
git submodule update --init
```

## License

MIT — see [`LICENSE`](LICENSE).
