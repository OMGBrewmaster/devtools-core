---
name: task-status
description: Read-only liveness and closure verdicts over this repo's tasks — finished-but-not-closed, premature or stale in-progress markers, bucket/status contradictions, rotted briefs, and (in queue repos) runner execution state
---

# Task status

Render a verdict on every task in this repo: is it actually live, is it actually
open, and does its brief still describe reality? Read this at session start when
you want to know where things stand before choosing work. It is cheap,
read-only, and repo-scoped — it never crosses into another clone, and it changes
nothing unless you accept an offered fix.

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below. If neither exists, print "No tasks directory found — run `/task-create` to scaffold one." and stop.
- **Repo scope**: this repo only. Resolve `git rev-parse --show-toplevel` once and confine every glob and every `git` invocation to it. A workspace checkout has sibling clones one directory up; walking into them is out of scope (a fleet sweep is a separate, later thing).
- **Component checkouts are separate repos.** A superproject can have no `<tasks>/` of its own while each of its submodules has one — `studio/found-in-words` is exactly that shape, with tasks living in `cms/docs/tasks` and `game-client/docs/tasks`. This skill does **not** descend into them. When the top level has no tasks root but a component checkout does, say so — "No tasks directory in this repo; `cms/` and `game-client/` have their own — run `/task-status` inside them" — rather than printing the bare not-found message, which reads as "this project tracks no tasks."
- **Discover buckets by globbing the resolved root, never by recursive grep from a parent directory.** In some environments `grep` is a wrapper that honors `.gitignore`, and a workspace root's `.gitignore` excludes the very project directories the clones live in. Such a search returns a *subset* and still exits `0`, so it is indistinguishable from a complete one. Glob the four bucket paths explicitly; if you must grep, pass the paths explicitly too.
- **Buckets**: `<tasks>/now/`, `soon/`, `later/`, `never/`. Exclude `README.md` and `_TEMPLATE.md`.
- **Queue**: `<tasks>/queued/` exists only in repos running the autonomous task-queue runner. `/task-list` declares it read-only runner territory; this skill is the one that *interprets* it. Its presence is the single switch that turns Phase 3 on. Absent → Phase 3 is skipped entirely, and the report says so rather than printing an empty section.
- **Dates come from git, never from the document.** Task documents carry no `Created` field by convention; creation is `git log --diff-filter=A --follow --format=%cs -- <file> | tail -1`.

## What this skill is not

| Skill | Question it answers |
|-------|---------------------|
| `/task-list` | **Inventory** — what tasks exist, in which bucket, with what metadata and AC progress. No verdicts. |
| `/task-next` | **Choice** — of the things that exist, what should I work on now. |
| `/task-audit` | **Per-task validity** — is *this* task still true against the codebase, deeply, one task at a time. |
| `/task-status` | **Liveness and closure** — across the whole set, which markers are lying, which briefs have rotted, and which finished work was never closed out. |

The overlap with `/task-audit` is real and bounded: `/task-audit` reads the
*codebase* to judge a task's claims; this skill reads *git and the task files*
to judge a task's bookkeeping. Where the two touch, this skill's rules are a
strict subset of `/task-audit` Phase 4, never a contradiction:

- `in-progress` → `not-started` on "no checked ACs and no relevant commits" is `/task-audit`'s own premature-marker rule, applied with the same evidence test.
- A fully-complete task is **flagged and offered for deletion**, never status-updated — matching `/task-audit` Phase 5 and the convention that completed tasks are deleted, not marked done.
- **This skill never moves a file between buckets.** Bucket placement belongs to `/task-reprioritize` and `/task-move`. A bucket/status contradiction is reported and handed off, not resolved here.
- Staleness has no counterpart in `/task-audit`, so a stale in-flight verdict never proposes a status flip — it reports and suggests `/task-audit` or `/task-implement`.

**The two skills count acceptance criteria differently, on purpose.**
`/task-list` defines progress as "checked (`- [x]`) vs total (`- [ ]` +
`- [x]`)", which silently omits the `[~]` partial marker from both sides of the
ratio. That is tolerable there — `/task-list` only *displays* a number, and a
display that is one criterion optimistic misleads nobody into an irreversible
act. Here the same number decides whether to offer a **deletion**, so this skill
counts every marker and treats anything other than `[x]` as not done. If the two
reports disagree about a task's progress, this one is the stricter and the
correct one; do not "reconcile" by loosening it.

If a verdict you are about to render would contradict `/task-audit`'s status
rules, stop and report it as an open question instead of guessing.

## Signal hygiene bindings

This skill exists to catch bookkeeping that lies, so its own checks must not.
Four bindings, all load-bearing (see `signal-hygiene.md`):

1. **Unknown is a verdict, printed in the findings, never folded into "clean."**
   The worked example is `scripts/sync/status.sh`'s `@{push}` block: `@{push}`
   exits non-zero printing nothing on a branch with no upstream — byte-identical
   to "no unpushed commits" — so the script tracks `unpushed_known` separately and
   prints `unpushed unknown (no upstream)` in red rather than `clean`. Do the same
   here. If a task's ACs cannot be parsed, print `AC state unknown — no checkbox
   list found`; do **not** print `0/0`. If `finalized-at` is absent, print `never
   verified`; do **not** print "no rot found". If `git cat-file -e <sha>^{commit}`
   fails (a dangling stamp, or a shallow clone that cannot reach it), print `rot
   unknown — finalized-at <sha> unreachable`; do **not** print a clean diff.

2. **Every count in the report is derived from git or from a file read in this
   run.** Nothing from memory, nothing from a previous session's report, nothing
   from the task document's own prose about its history.

3. **Before printing any check, ask what it prints if the work is not done.**
   The finished-not-closed verdict is the one that deletes a file, and it has
   two live ways to fire on unfinished work — both are guarded in *Counting
   acceptance criteria* above, and neither guard is removable:
   - `checked == total` is *true* when `total == 0`. Task files with no checkbox
     ACs exist in this fleet — some use plain bullets under
     `## Acceptance criteria`, some have no such section. **Guard on
     `total > 0`**, and report `total == 0` as `no machine-readable acceptance
     criteria`, never as completion.
   - Counting `[x]` against `[ ] + [x]` **drops the `[~]` partial marker
     entirely**, so a task with four done and one explicitly-partial criterion
     tallies 4/4 and is offered for deletion. **Total every marker; require
     every one to be `[x]`.**

4. **Read-only until accepted.** The only writes this skill may perform are the
   fixes in Phase 5, each individually accepted by the user. It never runs
   `git add`, `git commit`, `git mv`, or any other mutating git command.

---

## Phase 1 — Collect the evidence

Resolve `<tasks>/` and the repo root, then glob the four buckets. Print
"Found N tasks in <tasks>/ across B buckets." If zero, print "No tasks found in
`<tasks>/`." and stop.

For every task file, gather these facts. Each is a git or file read; none is a
judgement yet.

- **Frontmatter**: `status`, `effort`, `priority`, `dependencies`, `finalized-at`. Record a missing or unparseable frontmatter block as `frontmatter unknown`, not as defaults.
- **Bucket**: the parent directory name.
- **AC tally**: see *Counting acceptance criteria* below. It is the single most destructive thing in this skill to get wrong, so it gets its own section.
- **Commit history for the file**: `git log --follow --format='%H|%cs|%s' -- <file>`.
- **Scope paths**: the file paths named in the task's `## Scope` section, if it has one. Record `no Scope section` when absent — it is common, and Phase 2's rot check degrades explicitly on it.

### Counting acceptance criteria

Two rules, and neither is optional.

**Where to look.** Count **strictly inside** the `AC:BEGIN` / `AC:END`
sentinels when present; fall back to the `## Acceptance criteria` section when
they are not. Never count checkboxes from the whole file — task documents carry
checkbox lists in other sections (`## Steps`, `## Requirements`), and a
whole-file count silently reports the wrong section's progress as the task's. A
live example: a task with **zero** criteria under its `## Acceptance criteria`
heading has seven checked boxes under `## Steps`, so the naive count reports it
7/9 complete when the correct answer is *unknown*.

**What counts as a marker.** Three states occur in live data, not two:

| Marker | Meaning | Counts toward total | Counts as done |
|--------|---------|---------------------|----------------|
| `- [ ]` | Not done | yes | no |
| `- [x]` | Done | yes | yes |
| `- [~]` | **Partially done** — started, explicitly not finished | yes | **no** |

**Total is every `- [<any single character>]` marker. "Finished" requires every
marker to be exactly `[x]`.** Anything that is neither `[ ]` nor `[x]` — `[~]`
today, whatever someone invents tomorrow — must **block** the finished verdict
and be surfaced by name (`1 criterion in an unrecognized state: [~]`), never
folded into either bucket.

This is not hypothetical, and the failure mode is the worst one available to
this skill. Counted with the parser below on 2026-08-01: **5 `[~]` markers across
4 task files, and every one of them sits on an `in-progress` task** — the exact
population this skill judges. Treat the count as a sample rather than a
constant: it read 2 markers across 2 files earlier the same day, so it moved
within hours of being written down. The invariant worth relying on is not the
number but its shape — the marker keeps landing on in-progress work. A parser
that tallies only `[x]` against `[ ] + [x]` reads a task with four `[x]` and one
`[~]` as 4-of-4 complete and offers to **delete work that is not done**. A check
whose pass state is reachable by the very failure it exists to detect is worse
than no check: it reports success and ends the investigation.

If neither the sentinels nor a checkbox list under the heading exists, record
`AC unknown` (binding 3) — not `0/0`.

**Anchor the sentinel patterns to the start of the line.** A bare `/AC:BEGIN/`
also matches any line that *mentions* the sentinel — skill bodies, task READMEs,
and task documents about the task machinery all quote it in prose. Worse, the
`AC:BEGIN` rule ends in `next`, so a single line containing *both* names (a
`grep`/`awk` command line quoting the pair, which is exactly how anyone
demonstrates this parser) opens the block and never reaches the closing rule.
Everything from there to the real `AC:END` is then counted, including example
checkbox output — and if that example is all `[x]`, the tally reaches the
deletion verdict. All 164 real sentinels fleet-wide are anchored HTML comments;
every unanchored occurrence is prose. Match the anchored form only.

```awk
# Portable: no gawk-only 3-argument match(). Extract the marker with index()
# and substr() so this runs under mawk and BWK awk too.
/^<!-- AC:BEGIN/ { inac = 1; sentinels = 1; next }
/^<!-- AC:END/   { inac = 0; next }
!sentinels && /^## +Acceptance criteria/ { inac = 1; next }
!sentinels && inac && /^#/ { inac = 0 }
inac && /^[[:space:]]*- \[.\]/ {
  marker = substr($0, index($0, "[") + 1, 1)
  total++
  if (marker == "x" || marker == "X")  done++
  else if (marker != " ")            { unknown_state++; states = states "[" marker "]" }
}
END { printf "%d %d %d %s\n", done + 0, total + 0, unknown_state + 0, states }
```

### Dating the last substantive touch

`git log -1` on a task file dates the last time the file changed, which is not
the last time anyone *worked on the task*. Fleet-wide bookkeeping commits —
format migrations, queue rebalances, audit sweeps — touch dozens of task files
without advancing any of them, and they reset every naive date to the day of the
sweep. Walk the file's history newest-first and take the first commit that
passes the **substantive** test below.

Classify each commit `$c` against the task file `$task_file`:

```bash
# Fan-out: how many files under <tasks>/ this commit touched.
fanout=$(git show --name-only --format='' "$c" -- "$tasks_root" | awk 'NF' | wc -l | tr -d ' ')

# Body change: lines this commit changed in THIS file that are not
# frontmatter or legacy bold-metadata bookkeeping.
body_lines=$(git show "$c" -- "$task_file" | awk '
  /^(\+\+\+|--- )/ { next }                                  # diff headers
  /^[+-]/ {
    line = substr($0, 2)
    if (line ~ /^---[[:space:]]*$/) next                      # frontmatter fence
    if (line ~ /^(status|effort|priority|dependencies|finalized-at):/) next
    if (line ~ /^\*\*(Created|Status|Effort|Priority)\*\*:/) next   # pre-2026-07 format
    if (line ~ /^[[:space:]]*$/) next
    n++
  }
  END { print n + 0 }')
```

Count with `awk`, not `grep -c`: `grep` exits 1 when it matches nothing, which
is not a failure but does trip `set -o pipefail`, and the usual `|| true` patch
would swallow grep's exit 2 (a real regex error) along with it.

A commit is **bookkeeping, not work**, when either holds:

- `fanout >= 3` **and** `body_lines == 0` — it swept many task files and changed nothing but this one's metadata; or
- its subject matches the fleet's known bulk-migration vocabulary. Verified live on 2026-08-01: seven repos carry the identical subject `tasks: adopt the converged task-* skills and frontmatter format`, and hq carries `Adopt the converged task-* skills: migrate task docs, retarget wiring, …`. Both contain **"the converged task-\* skills"**. Treat that phrase as a known instance, not as the definition — the fan-out test is the general rule and the subject test is the backstop.

Every other commit is substantive. Its `%cs` is the **last substantive touch**;
the age is `today − that date`, in days.

If the whole history is bookkeeping, report `last substantive touch unknown —
only bookkeeping commits in history` and fall back to the creation date, labelled
as such. Do not silently present the sweep date as work.

**Degradation.** In a shallow clone (`git rev-parse --is-shallow-repository`
prints `true`) the history may not reach far enough to find a substantive
commit. Say `history truncated at <oldest reachable date> — age is a lower
bound` rather than reporting the truncation date as the answer.

---

## Phase 2 — Layer 1: task-state verdicts

Always runs. Apply every rule to every task; a task can earn more than one
verdict. A task earning none is current and is listed, unelaborated, at the end.

| # | Verdict | Test | Offered fix | Next step |
|---|---------|------|-------------|-----------|
| 1 | **Finished, not closed** | AC total `> 0`, **every marker exactly `[x]`** (no `[ ]`, no `[~]`, no unrecognized state), and the file is still on disk. The convention is that completed tasks are deleted. Not gated on `status` — a finished brief is finished whatever its frontmatter says. | Delete the brief — **only if it has no inbound links** (Phase 5) | `/task-implement` to close it out properly when links exist; `/task-reprioritize` if you would rather batch the closure |
| 2 | **Premature `in-progress`** | `status: in-progress`, zero ACs checked, and no substantive commit in the file's history (Phase 1's classifier) | Flip `status` to `not-started` | `/task-implement` to actually start it |
| 3 | **Stale in-flight** | `status: in-progress` and last substantive touch older than the threshold below | *none — no fix is unambiguous* | `/task-audit <task>` to see what moved underneath it, then `/task-implement` or `/session-land`'s blocked state |
| 4 | **Bucket/status contradiction** | `never/` holding anything but `not-started`; `blocked` with an empty `dependencies:` list and no blocker named in the body; a `dependencies:` entry naming no existing task file | *none — placement is not this skill's* | `/task-reprioritize` (bucket), `/task-move` (a single move), `/task-audit` (a dangling dependency) |
| 5 | **Rotted brief** | `finalized-at` present and resolvable, and `git log --oneline <sha>..HEAD -- <Scope paths>` is non-empty | *none* | `/task-finalize <task>` to re-verify against HEAD and re-stamp |
| 6 | **Invalid status value** | `status` is not one of `not-started` / `in-progress` / `blocked`. Both values seen live are aliases for "done" (`complete`, `pending`), so check rule 1 before assuming a typo — a `complete` task with every marker `[x]` is a closure, not a spelling mistake. | Flip to the nearest valid value, if one is obvious | `/task-audit` if it is not obvious |
| 7 | **No machine-readable ACs** | AC total is `0` or unparseable | *none* | `/task-finalize <task>` — readiness rule 2 requires at least one criterion |
| 8 | **Unrecognized AC marker** | Any marker inside the AC block that is neither `[ ]` nor `[x]` | *none* | Report the marker and the criterion verbatim; it blocks rule 1 by construction |

### The staleness threshold

**14 days** since the last substantive touch, for `in-progress` only. Calibrated
against the fleet on 2026-08-01, where it cleanly separates genuine in-flight
work (touched within a day or two) from markers left behind by an interrupted
run weeks earlier, with nothing sitting near the line. It is a default, not a
constant: say the threshold in the report so a reader can discount it, and treat
a task just past it as a prompt to look, not as a finding about the work.

### Rule 5 in detail — and how it degrades

The stamp is written by `/task-finalize` Phase 4c and means "the claims in this
document were verified true as of this commit." Resolve it before diffing:

```bash
git cat-file -e "${finalized_at}^{commit}" 2>/dev/null \
  || echo "rot unknown — finalized-at ${finalized_at} unreachable"
```

The `2>/dev/null` here is legitimate: the failure is *handled* by the fallback
that prints the unknown, not hidden.

Four degradations, each reported rather than skipped:

- **No `finalized-at`** → `never verified`. Most tasks in this fleet have no stamp; that is a fact about the task, not a clean bill of health.
- **Stamp present, no `## Scope` section** → diff the whole repo instead (`git log --oneline <sha>..HEAD`) and label the result `rot unscoped — N commits since verification, relevance unknown`. A repo-wide count over-reports by design; say so rather than reporting nothing.
- **Stamp unreachable** (dangling, or beyond a shallow clone's horizon) → `rot unknown`, per the binding above.
- **A Scope path this repo does not track** → `rot unknown` for that path. **Check this before diffing, every time.** `git log <sha>..HEAD -- <path>` prints nothing and exits 0 for a path that is untracked, gitignored, or in a different repository — byte-identical to "nothing changed there." The pass state of the rot check is therefore reachable by the exact condition that makes the check meaningless, which is the failure mode binding 3 exists to prevent.

  This is not a corner case. A task very often scopes work into a sibling clone or a submodule: hq's own tasks name paths under `devtools/`, which is a separate clone and is gitignored in hq, so **every one of them silently reports "no rot"** on a check that never looked at anything. Verify tracking first, and split the report:

  ```bash
  if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    git log --oneline "$sha..HEAD" -- "$path"          # a real answer
  else
    echo "rot unknown — '$path' is not tracked in this repo"
  fi
  ```

  The `2>/dev/null` is legitimate here: the failure is *handled* by the else branch, not hidden. Report a mixed result honestly — `2 of 5 Scope paths untracked; rot known only for the other 3` — and never let the tracked subset's clean diff stand in for the whole. If *no* Scope path is tracked, the verdict is `rot unknown`, full stop; it is not `current`.

---

## Phase 3 — Layer 2: execution state

**Skip this phase entirely unless `<tasks>/queued/` exists**, and say in the
report that it was skipped and why. Where it does exist, the runner's state
lives at `<repo root>/.task-queue/` (`locks/`, `logs/`, `worktrees/`, plus a
`stop` sentinel and any `STUCK-*.md` records).

Report:

- **Forensic marker files** in `<tasks>/queued/` — basenames carrying `.crashed`, `.merge-failed`, `.abandoned-wip`, `.dispatch-failed`, `.ci-stuck`, or `.partial`. The runner commits these when it cannot complete a task and then skips them at pickup, so each one is a task that will never be picked up again until a human acts.
- **`<tasks>/queued/blocked/`** contents — tasks the runner set aside.
- **Orphan branches**: for each `refs/heads/task-queue/*`, `git rev-list main..<branch>` non-empty **and** no live runner behind it. That is the runner's own definition of an orphan (`reconcile_orphans` in `task-queue/run.sh`) — commits that a crash left between "worker committed" and "runner merged". Point at `bash .claude/skills/task-queue/run.sh recover`; never merge one here.
- **Leftover worktrees** under `.task-queue/worktrees/` with no live runner, cross-checked against `git worktree list`.
- **`STUCK-*.md`** records under `.task-queue/`, and the **stop sentinel** `.task-queue/stop` (its presence means a graceful stop was requested — report it, since a stopped queue looks exactly like an idle one from the outside).

### Liveness is probed, never inferred

**A lock file existing proves nothing.** A crashed runner leaves its lock file
behind; a live runner and a dead one are indistinguishable on `ls`. The only
proof is failing to acquire the lock. This is the runner's own primitive
(`runner_alive_for_slug` in `task-queue/run.sh`) — use it, do not reimplement it
differently:

```bash
# Live iff the flock cannot be taken. Returns 0 = a live holder exists.
runner_alive_for_slug() {
  local slug="$1"
  local lock_file="$ROOT/.task-queue/locks/$slug.lock"
  [[ -e "$lock_file" ]] || return 1
  if exec 7>"$lock_file" && flock -n 7; then
    flock -u 7; exec 7>&-; return 1     # we got it → nobody holds it → dead
  fi
  exec 7>&-; return 0                    # blocked → a live runner holds it
}
```

If `flock` is not on `PATH` (it is Linux-only; macOS lacks it), report **`runner
liveness unknown — flock unavailable`** for every slug and continue. Do not fall
back to testing for the lock file's existence: that check reports "alive" for
precisely the crashed runners this phase exists to find, which is the
decorative-check failure mode in its purest form.

`claude agents` is not invokable from inside a session, so on-disk state probed
this way is the only cross-session view available.

---

## Phase 4 — Report

Print, in this order. Omit sections with no entries, except the two that must
always appear.

```
## Task status — <repo name> @ <short HEAD sha>

**N tasks** across <buckets>. Staleness threshold: 14 days.
<one line: queue present and probed / no queued/ — execution state not applicable>
```

Then one block per flagged task:

```
### <bucket>/<task-name>  —  <verdict>
Evidence: <the git output that produced the verdict — commit sha + date + subject,
          AC tally, diff counts. Quote it; do not paraphrase.>
Fix:      <the offered fix, or "none — needs judgement">
Next:     <the skill to run>
```

Then, **always**:

```
### Unknowns
<every value that could not be computed, with why. "None." if there are none.>

### Current
<tasks that earned no verdict, one line each.>
```

The Unknowns section is never omitted — an empty findings list with no Unknowns
section is indistinguishable from a run that failed to read anything.

---

## Phase 5 — Offer the fixes

Only two fixes are unambiguous enough to offer: **delete a finished-but-not-closed
task** (verdict 1) and **flip a status field** (verdicts 2 and 6). Nothing else
is offered — no bucket moves, no AC edits, no re-stamping.

If there are none, print "No unambiguous fixes to offer." and stop.

### Before offering a deletion, find what points at it

Deleting a brief breaks links in files this skill never read, and the deleting
commit is the canonical generator of that breakage. So a deletion is not
offerable until its inbound links are known — an offer made without them asks
the user to accept a consequence neither of you has looked at.

```bash
grep -rn "<task-slug>" --exclude-dir=.git .        # pass explicit paths if grep honors .gitignore here
```

Every hit outside the task file itself is an inbound link, and the count decides
whether the deletion is offerable at all:

- **Zero inbound links** → offer the deletion. `rm` is the whole fix.
- **One or more** → **do not offer the deletion.** Report the verdict with the
  hits listed, and route to `/task-implement`, which owns the whole close-out:
  its Phase 6c sorts inbound links into "broken by the deletion" and "already
  wrong" and repairs them *inside* the completing commit. Fixing them here is out
  of scope — this skill's writes are confined to the two fixes below, and
  rewriting another document's prose is not one of them. Offering the bare `rm`
  with the links merely named is the one path this section forbids: it converts a
  read-only report into the commit that dangles them.

This is not a rare shape. The finished-but-not-closed task found live in
`personal/home-automation` on 2026-08-01 carried two inbound references from a
sibling task in the same bucket; deleting it silently would have dangled both.

### The offer

For each fix that survived the check above, use `AskUserQuestion` with
`multiSelect: true`, one option per fix:

- Label: `<task-name>: delete (finished, no inbound links)` or `<task-name>: "in-progress" → "not-started"`
- Description: the one-line evidence summary from the report.

Apply **only** the accepted options — deletions with `rm`, status flips with
`Edit` on the frontmatter line. Then print exactly what was changed, and close
with:

> Do **NOT** auto-commit. Review the changes (`git status`, `git diff`) and commit when satisfied.

## See also

- `signal-hygiene.md` — the bindings above, and why an unknown reported as zero is worse than no check at all (this repo's copy is imported by the root `CLAUDE.md`; the path differs per repo, so it is named rather than linked)
- `task-queue/run.sh` — `runner_alive_for_slug` and `reconcile_orphans`, the primitives Phase 3 borrows
