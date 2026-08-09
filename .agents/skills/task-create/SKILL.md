---
name: task-create
description: Create a new task from the template
---

# Create Task

Create a new task document in this repo's tasks directory.

**Arguments**: $ARGUMENTS — optional `[task-name]` in kebab-case.

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below.
- **Queue**: anything mentioning `<tasks>/queued/` applies only when that directory exists (it feeds the autonomous task-queue runner). In repos without it, skip those parts silently.
- **Repo-specific authoring notes** (domain jargon to avoid in In brief, area maps, completion gates) live in `<tasks>/README.md` — read it before writing prose on the user's behalf.
- **Bucket definitions**: [`bucket-definitions.md`](bucket-definitions.md), the file next to this one — what each bucket means and the shape the queue aims for, shared with every other task skill so they cannot drift. A repo's own bucket lists are courtesy summaries of it, never a second definition.

## The template is single-source

The canonical task template is [`_TEMPLATE.md`](_TEMPLATE.md), the file next to this
one. Each repo exposes it at the familiar path as a **symlink**, never a copy:

```
<tasks>/_TEMPLATE.md -> <relative path back to repo root>/.claude/skills/task-create/_TEMPLATE.md
```

(For `docs/tasks/` that is `../../.claude/skills/task-create/_TEMPLATE.md`; for
`docs/planning/tasks/` it is `../../../.claude/skills/task-create/_TEMPLATE.md`.)

`.claude/skills/task-create/` is itself shared from `devtools/`, so one edit there
reaches every repo — the same way the skill body does. A copy would drift; a symlink
cannot. If you find a *regular file* at `<tasks>/_TEMPLATE.md`, that repo has fallen
out of the shared system — replace it with the symlink rather than editing it in
place (`devtools/Tools/migrate-task-format.sh` does this, among other things).

## Phase 1 — Check Structure

If no tasks root exists at all, offer to create one at `docs/tasks/` (the fleet
default location):
- `docs/tasks/` with a `README.md`, plus `_TEMPLATE.md` created as a symlink:

  ```bash
  ln -s ../../.claude/skills/task-create/_TEMPLATE.md docs/tasks/_TEMPLATE.md
  ```

  Verify it resolves (`cat docs/tasks/_TEMPLATE.md`) before continuing — a dangling
  link means the shared skills are not available in this repo.
- `docs/tasks/now/`, `docs/tasks/soon/`, `docs/tasks/later/`, `docs/tasks/never/` each with a one-liner `README.md`. Write each one-liner from [`bucket-definitions.md`](bucket-definitions.md) and point at it for the definition of record — the one-liner is a courtesy summary, not a second definition. Write that pointer as the repo-root-relative path in prose (`devtools/.claude/skills/task-create/bucket-definitions.md`), **not** a markdown relative link: devtools sits outside the tasks tree, so a `../../..` hyperlink renders broken on GitHub even where it resolves on disk. (Do **not** create `queued/` — an autonomous queue is a deliberate per-repo opt-in, not scaffolding.)

If the user declines, stop.

## Phase 2 — Gather Info

1. If no task name was provided in `$ARGUMENTS`, ask for one (kebab-case, action-verb-first, e.g., `fix-login-crash`).
2. Ask which bucket to place the task in. Options: `now`, `soon` (default), `later`. (`never/` is not offered at creation — a task is parked there later via `/task-move`; see [`bucket-definitions.md`](bucket-definitions.md). Tasks heading for autonomous execution are still created in a normal bucket first — `/task-finalize` moves them to `queued/` once they pass readiness.)
3. Ask for a brief goal statement (1-2 sentences starting with an action verb).
4. Ask for effort estimate: `small`, `medium` (default), or `large`.
5. Priority defaults to `medium` and dependencies to `[]` — don't ask unless the user signals urgency (then offer `high`/`medium`/`low`) or names other tasks this one must wait for (then record their slugs as dependencies).

## Phase 3 — Create File

1. Read `<tasks>/_TEMPLATE.md` (the symlink resolves to this skill's `_TEMPLATE.md`).
2. Copy it to `<tasks>/{bucket}/{task-name}.md`.
3. Fill in:
   - Replace `# Task Title` with `# {title}` (derived from task-name, converting kebab-case to sentence case — capitalize only the first word and proper nouns, per the doc style guide).
   - In the YAML frontmatter: set `status: not-started`, `effort:` and `priority:` to the chosen values, and `dependencies:` to the recorded slugs (or `[]`).
   - Replace the Goal section placeholder with the provided goal statement.
   - Write `**In brief**:` — one short plain-language paragraph derived from the goal
     statement, following the guidance in the template's comment (no jargon, no
     identifiers, no file paths — including any repo domain terms flagged in
     `<tasks>/README.md`). It exists so a reader can triage the task without opening
     the codebase, so write it for someone who has never seen this repo. Show it to
     the user and adjust if they want it different.

   Do **not** add a Created line or `created:` field — the creation date is derived from `git log --diff-filter=A --follow` when needed.
4. Remove HTML comments from the sections that were filled in (Goal metadata block, the `**In brief**:` paragraph). Leave HTML comments in unfilled sections as guidance.
5. Strip the template-only preamble (the HTML-comment block above `# Task Title` describing the template's purpose and listing key references) and the See-also footer (HTML-comment block at the very end). Both are meant for readers of the template, not for authored tasks.

## Phase 4 — Confirm

Print: "Created `<tasks>/{bucket}/{task-name}.md`."

## Phase 5 — Offer to Finalize

`/task-finalize` walks open questions interactively, verifies the task's claims against HEAD, and validates readiness — and, in repos with a queue, offers to move the task to `queued/` for the autonomous runner.

Use `AskUserQuestion` (single-select, `multiSelect: false`) to ask:

- **question**: "Run `/task-finalize` now to verify against HEAD and resolve open questions?" (append "— and possibly promote to `queued/`" only in repos with a queue)
- **header**: "Finalize now?"
- options:
  - `Yes — finalize now` — invoke the `/task-finalize` skill on this task immediately, passing the new file path as the argument. (Recommended when the task is small and the open questions are already in your head.)
  - `No — leave it here` — stop. The user will run `/task-finalize` later.

If the user picks Yes, hand off to `/task-finalize <path-to-new-task>`. If No, stop.

## Phase 6 — Ship it (docs-only fast path)

Runs only when Phase 5 ended with "No — leave it here" (a finalize hand-off
reaches the same offer through `/task-finalize`'s own closing phase). If the
repo's AGENTS.md documents a docs-only shipping convention (a "Shipping
docs-only changes" section naming a predicate script), offer to ship the new
task now:

- **Local session** (pushes to the default branch are not blocked): confirm
  `git status --short` shows only this task file, commit it on the default
  branch, then run the predicate script against the remote default branch
  (e.g. `scripts/docs-only-diff.sh origin/main`). Exit 0 → push, and read the
  push's own output as the verification. Any other exit → do **not** push:
  name what else the outgoing range carries and leave the commit local.
- **Cloud session** (git proxy, PR flow): note that `/ship` carries docs-only
  PRs to merge without a review pause under the maintainer's standing
  delegation (2026-07-29).

No such AGENTS.md section → stop; shipping stays the session's normal flow.
