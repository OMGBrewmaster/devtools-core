# Workshop

Shared agent skills in the [Agent Skills](https://agentskills.io/specification)
open-standard format — readable by Claude Code, Codex, Cursor, Copilot, and the
rest of the ~40 harnesses that implement the spec — plus documentation standards
and tooling for task management and documentation review. Read this if you have
found the repo on its own, or if you are working in a project that mounts it as
a submodule.

Workshop is the public identity of OMG Brews' shared developer tooling: the
safe-to-share subset of the private `OMGBrews/devtools` repository, published
automatically. It is the first visible step of a plan to make this repository
the tooling's real home; until that inversion happens, the private repository
remains the source of truth and this repo is a generated mirror of its
publishable subset.

## This repository is generated

The contents are published automatically from the private upstream repository on
every change there, and republished on a daily schedule so that a publish which
never ran cannot leave this copy behind indefinitely. The schedule **bounds**
that staleness rather than eliminating it: a publish that never ran is corrected
within roughly a day, not immediately. If you need to know whether a given
commit here is current, read its message — each one names the upstream commit it
was generated from. **Nothing here is edited by hand**, and anything committed
directly is overwritten by the next publish.

- **No pull requests.** They cannot be merged — the next publish would discard
  them.
- **Issues and suggestions** are welcome; they are triaged upstream.

## What is here

| Path | What it is |
|------|-----------|
| `.agents/skills/task-*` | Agent skills for the task system — create, list, move, audit, reprioritize, finalize, pick the next one, implement it, report status, and run the autonomous queue |
| `.agents/skills/docs-audit` | Documentation audit skill — style compliance, navigation, accuracy |
| `.agents/skills/kaizen-resolve` | Closes out a continuous-improvement problem document once its flaw is verifiably gone |
| `.claude/skills/*` | One symlink per skill into `.agents/skills/`, so Claude Code — which does not yet read the standard path — finds them too |
| `Tools/sync-skill-symlinks.sh` | Regenerates a project's per-skill symlinks on both surfaces |
| `docs/signal-hygiene.md` | How to know a step actually happened — read exit codes, never suppress output |
| `docs/definition-of-done.md` | What "done" requires, and where each repo names its own gates |
| `docs/templates/` | Copy-paste-ready templates for architecture docs, feature docs, ADRs, and directory READMEs |

The task skills are repo-agnostic: they find the tasks directory themselves
(`docs/work/tasks/`) and turn on queue behaviour only where a
`queued/` bucket exists.

## What it deliberately lacks

- **Anything private to OMG Brews.** This is a mirror of the safe-to-share
  subset only: no client names, no studio-internal references, no personal
  detail, no propagation run logs. If you find something here that reads
  private, it is a publish bug — report it upstream.
- **The full devtools repository.** The private repo carries much more than
  this subset — fleet inventories, internal tooling, private standards — and
  none of that is published. The published set is exactly what
  `mirror/manifest.txt` lists in the upstream repo, and it changes only by
  deliberate edit there.
- **Contribution surface.** No pull requests, no hand edits — see "This
  repository is generated" above.

## Using it in a project

Mount it as a submodule and link the skills you want into `.agents/skills/`, the
[Agent Skills](https://agentskills.io/specification) discovery path:

```bash
git submodule add https://github.com/OMGBrewmaster/workshop.git workshop
ln -s ../../workshop/.agents/skills/task-list .agents/skills/task-list
```

Claude Code does not read `.agents/skills/` yet, so add a bridge link per skill
beside it — one symlink, never a directory-level one:

```bash
ln -s ../../.agents/skills/task-list .claude/skills/task-list
```

Cloning a project that mounts it needs no credentials of any kind:

```bash
git clone --recurse-submodules <project-url>
# or, in an existing clone:
git submodule update --init
```

## Pinning a version

A consuming project pins the submodule at a specific commit and moves that
pointer when it chooses, so an upstream change never lands in a project without
someone asking for it. **Pin by tag, not by arbitrary publish commit** — tags
are the stable, citeable versions:

```bash
git -C workshop fetch --tags origin
git -C workshop checkout v0.1.0
# or, from the superproject:
git submodule update --init --checkout workshop
```

Current versioning policy is deliberately manual: tags are cut by hand at
milestones (v0.1.0 is the first), there is no release automation, and no
semantic-versioning promise beyond "the tag is the version". Release automation
and a cadence are planned for when this repository becomes the tooling's source
of truth; until then, a tag means "this snapshot was good enough to name".
Tags survive the automatic publishes — the publish flow preserves `.git` and
pushes without force — so a pinned tag never moves under you.

## License

MIT — see [`LICENSE`](LICENSE).
