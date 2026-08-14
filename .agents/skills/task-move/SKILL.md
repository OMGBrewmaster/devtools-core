---
name: task-move
description: Move a task between priority buckets
---

# Move Task

Move a task file between priority buckets in this repo's tasks directory.

**Arguments**: `[task-filename] [target-bucket]` (e.g., `fix-login-crash now`).

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` if it exists, else the legacy `docs/tasks/`, else `docs/planning/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` exists only in repos running the autonomous task-queue runner. Where it is absent, `queued` is not a valid bucket and Phase 3 never applies.

## Phase 1 — Find the Task

Search for the task file across all buckets (`now/`, `soon/`, `later/`, `never/`, and `queued/` where it exists). Match by filename (with or without `.md` extension).

If the task is not found, list available tasks and ask the user to pick one.

If no task name was provided in the arguments, list all tasks and ask which one to move.

## Phase 2 — Validate Target

If no target bucket was provided in the arguments, ask where to move it. Valid targets: `now`, `soon`, `later`, `never` — plus `queued` in repos where `<tasks>/queued/` exists.

If the task is already in the target bucket, print "Task is already in `{bucket}/`." and stop.

## Phase 3 — Readiness Check (only when moving INTO queued/)

If the target bucket is **anything other than `queued`**, skip this phase.

Tasks in `queued/` are picked up by the autonomous task-queue runner with no further triage. Refuse moves into `queued/` unless the shared readiness checker passes against the current task file:

Resolve `check-task-readiness.sh` from the `task-finalize` skill's physical directory, then run it on the current task file and read every `PASS` / `FAIL` / `WARN` line plus the exit code:

```bash
skill_dir="$(cd -P "$(dirname "$(readlink -f .agents/skills/task-finalize/SKILL.md)")" && pwd)"
checker="$skill_dir/check-task-readiness.sh"
readiness_rc=0
readiness_output="$(bash "$checker" "$task_file")" || readiness_rc=$?
printf '%s\n' "$readiness_output"
printf 'EXIT=%s\n' "$readiness_rc"
```

Exit 0 is admission-ready. Exit 1 means the numbered `FAIL` records are the reasons to refuse; `WARN` records alone do not block the move. Exit 2 means the checker could not derive the task file's repository context, so stop and fix that before considering the move.

If the checker exits 1:

1. Print the specific failures.
2. Print: "Refusing to move into `queued/`. Run `task-finalize {task-name}` to resolve the issues interactively (it walks open questions one at a time in conversation, stamps `finalized-at:`, and runs this same checker), then re-run this move."
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

If the target was `queued/`, also print: "The task-queue runner will pick this up on its next poll cycle (if running) — it reads main's HEAD, not the working tree, so this rename stays invisible to it until the commit lands. Start the runner with `bash .claude/skills/task-queue/run.sh` (the `.claude/skills/` path is the Claude Code bridge into the canonical `.agents/skills/` tree)."

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
  the `ship` skill carries docs-only PRs to merge without a review pause under the
  maintainer's standing delegation (2026-07-29).

No such AGENTS.md section → stop at Phase 5; shipping stays the session's
normal flow.
