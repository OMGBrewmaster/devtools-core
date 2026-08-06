---
name: task-move
description: Move a task between priority buckets
argument-hint: "[task-filename] [target-bucket]"
---

# Move Task

Move a task file between priority buckets in this repo's tasks directory.

**Arguments**: $ARGUMENTS — `[task-filename] [target-bucket]` (e.g., `fix-login-crash now`).

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below. If neither exists, print "No tasks directory found — run `/task-create` to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` exists only in repos running the autonomous task-queue runner. Where it is absent, `queued` is not a valid bucket and Phase 3 never applies.

## Phase 1 — Find the Task

Search for the task file across all buckets (`now/`, `soon/`, `later/`, `never/`, and `queued/` where it exists). Match by filename (with or without `.md` extension).

If the task is not found, list available tasks and ask the user to pick one.

If no task name was provided in `$ARGUMENTS`, list all tasks and ask which one to move.

## Phase 2 — Validate Target

If no target bucket was provided in `$ARGUMENTS`, ask where to move it. Valid targets: `now`, `soon`, `later`, `never` — plus `queued` in repos where `<tasks>/queued/` exists.

If the task is already in the target bucket, print "Task is already in `{bucket}/`." and stop.

## Phase 3 — Readiness Check (only when moving INTO queued/)

If the target bucket is **anything other than `queued`**, skip this phase.

Tasks in `queued/` are picked up by the autonomous task-queue runner with no further triage. Refuse moves into `queued/` unless every rule below passes against the current task file:

| # | Rule | How to check |
|---|------|--------------|
| 1 | Goal section non-empty and not a placeholder | `## Goal` block exists, has non-comment content, doesn't include the template placeholder text |
| 2 | At least one acceptance criterion listed | `## Acceptance criteria` contains ≥1 `- [ ]` or `- [x]` item whose text is not an angle-bracket placeholder (`<…>`, e.g. `<first acceptance criterion>`). Sentinel lines `<!-- AC:BEGIN -->` / `<!-- AC:END -->` inside the section are ignored when scanning for items. |
| 3 | Stopping conditions non-empty | `## Stopping conditions` exists, has non-comment content |
| 4 | Status field chosen | The frontmatter `status:` value is one of `not-started` / `in-progress` / `blocked`. Fails if the frontmatter block is missing or the value is the template placeholder (`<not-started \| in-progress \| blocked>`). |
| 5 | Effort field chosen | The frontmatter `effort:` value is one of `small` / `medium` / `large`. Fails if the value is the template placeholder (`<small \| medium \| large>`). |
| 6 | Open questions resolved | `## Open questions` is absent or contains only whitespace/comments |
| 7 | Priority and dependencies well-formed | The frontmatter `priority:` value is one of `high` / `medium` / `low`, and `dependencies:` is a (possibly empty) list of kebab-case task slugs — warn if a listed slug matches no existing task file or queue history. |
| 8 | Context verified at HEAD | The frontmatter `finalized-at:` value is a valid commit SHA in this repo (`git cat-file -e <sha>^{commit}`). Only `/task-finalize`'s verify-against-HEAD phase stamps it — so a task failing this rule needs `/task-finalize`, not a hand-added SHA. |

If any rule fails:

1. Print the specific failures.
2. Print: "Refusing to move into `queued/`. Run `/task-finalize {task-name}` to resolve the issues interactively (it walks open questions via `AskUserQuestion`, validates the same rules, and offers to do this move for you)."
3. Stop without moving.

If all rules pass, proceed.

## Phase 4 — Move

Move the file. `git add` the source first so this works whether the task is untracked (newly created), tracked-clean, or tracked-modified — `git mv` alone errors on untracked sources:

```bash
git add <tasks>/{source-bucket}/{task-name}.md \
  && git mv <tasks>/{source-bucket}/{task-name}.md <tasks>/{target-bucket}/{task-name}.md
```

## Phase 5 — Confirm

Print: "Moved `{task-name}.md` from `{source-bucket}/` to `{target-bucket}/`."

If the target was `queued/`, also print: "The task-queue runner will pick this up on its next poll cycle (if running). Start the runner with `bash .claude/skills/task-queue/run.sh`."

## Phase 6 — Ship it (docs-only fast path)

If the repo's AGENTS.md documents a docs-only shipping convention (a "Shipping
docs-only changes" section naming a predicate script), offer to ship the move
immediately after Phase 5 — task moves are the exact churn that convention
exists for:

- **Local session** (pushes to the default branch are not blocked): confirm
  `git status --short` shows only this move staged, commit it on the default
  branch, then run the predicate script against the remote default branch
  (e.g. `scripts/docs-only-diff.sh origin/main`). Exit 0 → push, and read the
  push's own output as the verification. Any other exit → do **not** push:
  the outgoing range carries non-docs changes, so name them and leave the
  commit local for the normal flow.
- **Cloud session** (git proxy, PR flow): nothing to do here — note that
  `/ship` carries docs-only PRs to merge without a review pause under the
  maintainer's standing delegation (2026-07-29).

No such AGENTS.md section → stop at Phase 5; shipping stays the session's
normal flow.
