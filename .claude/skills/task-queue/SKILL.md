---
name: task-queue
description: Show how to start the autonomous task-queue loop runner that watches the tasks directory's queued/ bucket and processes each task in a fresh Claude Code session.
---

# Task Queue Loop

Autonomously processes tasks from `<tasks>/queued/` one at a time, each in a
fresh Claude Code session. (`<tasks>` is the repo's tasks root: `docs/tasks/`
if it exists, else `docs/planning/tasks/` — `run.sh` detects this itself. A
repo opts into the queue by creating `<tasks>/queued/`; without that
directory this skill doesn't apply.)

This slash command is **documentation only** — it tells the user how to start
the loop runner. The loop has to run at the shell level (a slash command can't
spawn fresh `claude` sessions to replace itself), so this skill never launches
anything on its own. Print the section below verbatim and stop.

This skill is self-contained: the loop runner (`run.sh`), the worker prompt
(`initial-prompt.md`), and the operator notes (`README.md`) all live in this
skill's own directory alongside this file.

## How it works

- A small shell loop (`run.sh`, bundled in this skill directory) polls
  `<tasks>/queued/` every few seconds.
- When at least one `*.md` file is present, the loop dispatches a worker via
  `claude --bg --name <task-slug> --permission-mode bypassPermissions`. The
  worker registers with the Agent View supervisor, so it's listed in
  `claude agents`, its terminal is queryable via `claude logs <slug>`, and
  the same name appears at claude.ai/code and in the Claude mobile app. The
  prompt tells the new session to pick the most appropriate task, implement
  it, `git rm` the file, commit, and self-terminate. `bypassPermissions`
  skips all prompts; only run the loop in a sandboxed host environment.
- When that session exits, the loop checks the queue again — immediately if
  non-empty, otherwise polling until a new file appears.
- Each task runs in a **fresh** Claude Code session (clean context, no
  carry-over from previous tasks).
- The user can answer clarifying questions either in the runner's terminal,
  via `claude agents` from a separate terminal, or remotely at
  claude.ai/code / the Claude mobile app (the session appears under its
  task-slug name; `AskUserQuestion` calls fire mobile pushes).
- If a session crashes or times out with the task file still in `queued/`,
  the loop renames the file `*.crashed.<timestamp>.md` so the queue doesn't
  loop forever on a poison task.
- **Runs in parallel.** Launch `run.sh` N times at once and the
  runners cooperate: each claims a different task (non-blocking `flock`
  per task slug) and writes to `main` are serialized through one shared
  lock. See `README.md` → *Running multiple runners in parallel*.
- **Auto-detaches on launch.** `run.sh` re-execs itself under
  `setsid script` so the runner survives the launching terminal closing
  and never gets SIGHUP'd. It returns immediately, printing the detached
  pid and the runner-log path.
- **Reconciles orphaned branches on launch.** If a previous runner was
  killed (SIGKILL / OOM / container restart) between a worker committing
  and the runner merging, the orphaned `task-queue/*` branch is detected
  and reported on the next launch. Run `bash ${CLAUDE_SKILL_DIR}/run.sh
  recover` to merge it into `main` and clean up — recovery is always a
  deliberate operator action, never automatic.

## Starting the runner

```bash
bash ${CLAUDE_SKILL_DIR}/run.sh
```

(`${CLAUDE_SKILL_DIR}` resolves to this skill's directory —
`devtools/.claude/skills/task-queue/`, also reachable as
`.claude/skills/task-queue/` via the skills symlink.)

The runner **auto-detaches**: it re-execs itself under `setsid script`,
returns immediately, and prints the detached pid plus the runner-log path
(`.task-queue/runner-<ts>-<pid>.out`). Watch progress with `tail -f` on
that log; watch the workers with `claude agents`. The runner survives the
launching terminal closing.

Pass `--foreground` to run in the current terminal instead (live stdout,
for debugging the runner itself).

For more throughput, run the same command **several times at once** — the
runners coordinate via locks and pick up different tasks. 2–3 is a sensible
ceiling on a dev container.

Then drop task files into `<tasks>/queued/`. They'll be picked up
on the next poll cycle.

If a previous runner was killed mid-merge, its branch is reported on launch;
run `bash ${CLAUDE_SKILL_DIR}/run.sh recover` to merge orphaned branches into
`main` and clean up their worktrees, branches, and locks.

### Stopping the runner

```bash
bash ${CLAUDE_SKILL_DIR}/run.sh stop
```

This is a **graceful stop**: it touches the global stop sentinel, and every
running runner of this queue finishes its current iteration — including
merging the in-flight worker's branch — then exits at the iteration
boundary. It works from any terminal and needs no pid.

To stop just one runner, send it a single `SIGTERM`: `kill -TERM <pid>`
(or `Ctrl+C` if you launched it with `--foreground`). A **second** signal
escalates to a **fast stop** — the in-flight worker is `claude stop`ped
rather than waited on, and the runner exits promptly.

### From a non-interactive context (Claude session, CI, no terminal access)

No special wrapper is needed. Because the runner auto-detaches under
`setsid script` on every launch (allocating its own pty and shedding the
controlling terminal), a plain `bash ${CLAUDE_SKILL_DIR}/run.sh` works
identically from a terminal, a Claude session, CI, or an SSH connection.

See [`README.md` → Launching from a non-interactive
context](./README.md#launching-from-a-non-interactive-context) for the
full pattern.

## More

- The repo's task-queue procedure doc, where one exists (e.g. `docs/procedures/development/task-queue.md`) — full end-to-end pipeline orientation
  (`/task-create` → `/task-finalize` → `queued/` → autonomous runner) plus
  troubleshooting and known limitations.
- [`README.md`](./README.md) — operator details (logs, timeouts,
  multi-Claude-sandbox safety, blocked-task handling), bundled alongside this
  file in the skill directory.
