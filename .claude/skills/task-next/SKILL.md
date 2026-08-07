---
name: task-next
description: Recommend the single best task to start next in this repo — ranked by the shared rubric, weighted by the repo's focus document, and validated against HEAD before it is recommended
argument-hint: "[optional constraint, e.g. 30m / tired / no Unity]"
---

# Next Task

Answer "what should I work on right now?" for **this repository**. Read the pending
tasks, rank them against the shared rubric, weight them by what the owner said matters,
validate the top pick against HEAD, and recommend exactly one — with the reasoning in
plain language, one or two alternates, and an explicit reason for every obvious
contender that lost.

`/task-list` inventories, `/task-reprioritize` ranks in order to shape buckets, and
`/task-audit <task>` judges a task you have already chosen. This skill is the one that
chooses.

**Arguments**: `$ARGUMENTS` — one optional free-form constraint in plain language
("30m", "tired", "no Unity", "nothing that needs the CMS running"). There is no flag
grammar; read it the way a person would.

This skill is **read-only**: it moves nothing, edits nothing, commits nothing, and
starts nothing. It ends by *offering* the next command. The user runs it.

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below. If neither exists, print "No tasks directory found — run `/task-create` to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` (when it exists) holds tasks the autonomous runner has claimed. Read it as context for area-coupling only — never recommend a queued task; the runner owns it. In repos without it, skip everything that mentions it.
- **Bucket definitions**: [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md), relative to this skill's directory — what each bucket means, shared with every other task skill so they cannot drift. If that path does not resolve (a repo whose `task-create` symlink is missing), read `devtools/.claude/skills/task-create/bucket-definitions.md` and say you fell back.
- **`never/` is never a candidate**: parked tasks are excluded from ranking. Do not read them as candidates.
- **Ranking rubric**: [`../task-reprioritize/ranking-rubric.md`](../task-reprioritize/ranking-rubric.md), relative to this skill's directory — the same rules `/task-reprioritize` applies, so the two cannot drift. If that path does not resolve (a repo whose `task-reprioritize` symlink is missing), read `devtools/.claude/skills/task-reprioritize/ranking-rubric.md` and say you fell back.
- **Focus document**: `<tasks>/focus.md` — the owner's statement of what matters right now. Format, staleness rule, and degradation are specified in the rubric's [Focus weighting](../task-reprioritize/ranking-rubric.md#focus-weighting-tasksfocusmd) section.
- **Creation dates** are not stored in task documents — there is no `Created:` field. Derive them from the file's first commit using the command [the rubric defines](../task-reprioritize/ranking-rubric.md#readiness-and-evidence-signals), so this skill and `/task-reprioritize` cannot drift on date format.

## Scope: this repository, and nothing else

Resolve the tasks root under this repo's own root (`git rev-parse --show-toplevel`).
**Never enumerate, glob, or read a task directory outside it.** In a workspace where
sibling projects sit one directory away, those are separate repositories with their own
queues, and their tasks are not candidates here — the whole point of per-repo selection
is to support working on one project at a time. If the user wants a different project's
next task, they run this skill in that project.

---

## Phase 1 — Read the focus document

Look for `<tasks>/focus.md`.

**Present** — read it and extract two things: the prose statement and the optional
`**Not now:**` line. It states the repo's *direction* and does not name a next task
(rubric § [Direction, not a next task](../task-reprioritize/ranking-rubric.md#direction-not-a-next-task)),
so nothing in it decides the pick outright — it weights. Then derive when it was last
touched:

```bash
git log -1 --format=%cs -- <tasks>/focus.md
```

Read that command's actual output, and branch on all three cases:

| Output | Meaning | What to do |
|--------|---------|------------|
| A date within ~30 days | Current | Use it; report the date |
| A date older than ~30 days | Possibly stale | Use it anyway, and **ask in the output** whether it still holds |
| **Empty** (exit 0, no output) | The file exists but has never been committed | Say "staleness unknown — `focus.md` is not committed yet". **Never read empty as fresh** |

That third row is the trap: the command succeeds and prints nothing for an uncommitted
file, so a check that only looks at the exit code reports a healthy, current focus
document for one git has never seen.

**Absent** — say so, in the output, in as many words: "No `<tasks>/focus.md` — ranking on
mechanics alone." Then continue. Silent degradation is the failure to avoid here: the
user must never mistake a mechanics-only ranking for one that honored a focus they
believed was being read. Close by showing the format (rubric § Focus weighting) so
writing one is a small step.

---

## Phase 2 — Build the candidate pool

Glob `<tasks>/now/*.md`. Exclude `README.md`, `_TEMPLATE.md`, `.gitkeep`, and `focus.md`
(it sits at the tasks root, not in a bucket, so a bucket glob will not reach it — but say
so if you ever glob the root).

Backfill in this order, and stop as soon as the pool holds at least three candidates that
survive Phase 3:

1. `<tasks>/now/` — always.
2. `<tasks>/soon/` — when `now/` is thin (fewer than two candidates) or every `now/`
   candidate is screened out as blocked. Label these "(backfilled from `soon/`)".
3. `<tasks>/later/` — only when `now/` and `soon/` together yield nothing workable.
   Label these "(backfilled from `later/` — the queue is dry)".

Read `<tasks>/queued/*.md` (where it exists) for their areas only — context for the
rubric's coupling tiers, never candidates.

For each candidate, extract: the H1 title, the frontmatter (`status`, `effort`,
`priority`, `dependencies`, `finalized-at`), the **In brief** paragraph, the first
sentence of `## Goal`, the paths in `## Scope`, the acceptance-criteria items with their
checked count, and the `## Open questions` section.

---

## Phase 3 — Screen every candidate (cheap)

A task brief is a cache of code observations, and a recommendation is a cache read. Screen
the whole pool cheaply here; the expensive validation runs on the top pick alone (Phase 5).
"Cheap" means file reads, path existence, and `git cat-file` — **no codebase analysis, no
greps over the source tree, no subagents**.

Assign each candidate a **readiness tier**:

| Tier | Test | Reads as |
|---|---|---|
| **1 — finalized** | `finalized-at:` present and resolves (`git cat-file -e <sha>^{commit} 2>/dev/null`), `## Open questions` absent or empty, acceptance criteria are real items rather than `<angle-bracket placeholders>` | Ready to execute |
| **2 — ready, unfinalized** | Passes every Tier 1 test except `finalized-at:` | Workable, but needs `/task-finalize` to lock the design and stamp the verification point |
| **3 — open questions** | `## Open questions` has non-comment content | Needs a decision conversation before code |
| **4 — placeholder-shaped** | Goal or acceptance criteria are still template placeholders | Needs writing before it needs doing |

Outside the repos running the autonomous queue, Tier 2 is the normal state — most tasks
have never been finalized. **Tiers order and label candidates; they never hide one.** A
Tier 2 or Tier 3 task can absolutely be the recommendation; it is presented with the step
it needs first.

Separately, flag **blockers** — these do remove a task from the ranked pool, but into a
reported list, never into silence:

- `status: blocked` — quote the reason from the document if it names one.
- A `dependencies:` entry naming a task that still exists unfinished in a bucket.
- Every path in `## Scope` missing at HEAD *and* the task's language says it is changing
  those paths rather than creating them. (A task that proposes to create files is
  supposed to have paths that do not exist yet — do not call that blocked.)

Finally, screen each survivor for **startability** (rubric § Startability): can its
*remaining* work begin in this session, or does it first need a precondition nobody has
arranged — a repo state this repo lacks, an occasion nobody can manufacture on demand,
or another task's output? Read the **unchecked** criteria to answer it; a gated task is
invisible in metadata, because it looks maximally ready right up until you ask what is
left of it.

Gated is **not** blocked, and the two are reported differently: a blocked task leaves
the ranked pool for the blocked list, while a gated task stays in the ranking and is
demoted within it. Apply the rubric's guard — name the precondition concretely or do
not call it gated.

---

## Phase 4 — Rank the survivors

Read [`ranking-rubric.md`](../task-reprioritize/ranking-rubric.md) and apply it, reading
its bucket vocabulary as ranking strength (the rubric's own "How each skill reads this
document" table gives the translation).

Apply in this order:

1. **In-flight pinning** (rubric § In-flight pinning) — a task with `status: in-progress`
   or any checked acceptance criteria is **presumptively the pick**. Resume beats start:
   picking up something new instead leaves two half-done tasks and the abandoned one rots.
2. **Readiness and evidence signals** (rubric § Readiness and evidence signals) — these
   override ordinary ranking. A task whose criteria are all checked is not a candidate at
   all; report it as "looks finished — close it out" instead.
3. **Startability** (rubric § Startability) — demote every candidate whose remaining work
   is gated, and say which gate. This is the rebuttal to step 1: the pool's most advanced
   in-flight task is the wrong pick when its unchecked criteria cannot be started today,
   and that case is common enough to rank ahead of the tiebreakers rather than be
   discovered afterwards. If *every* candidate is gated, that is the finding — report it
   like the all-blocked case and recommend creating the precondition that frees the most.
4. **Placement categories** (rubric § Placement categories) — **N** ranks above **S**
   ranks above **L** for starting now. An **L** task is one to plan, not to pick up
   casually; recommend it only when it is what the focus document asks for, and say so.
5. **Coupling tiers and tiebreakers** (rubric §§ Area-coupling tiers, Tiebreakers) —
   progress, then age, then smaller effort.

Then weight the ranking by the three inputs the rubric leaves to this skill:

### The `priority:` field is a weak signal

Read `priority:`, but do not rank on it. Across the fleet it is the untouched template
default `medium` on roughly four task documents in five — so `medium` means "nobody set
this", not "middling importance", and ranking on the field would mostly rank on which
tasks happened to get edited. Treat an explicit `high` as a nudge upward and `low` as a
nudge down, decided by the rubric's tiebreakers when they are close. A `high` task that
loses anyway must appear under "Passed over" with a real reason — someone deliberately
typed that value, and silently dropping it is how the field becomes even less trusted.

### Focus weighting

- The prose statement raises every candidate it covers — matched by the one rule in the
  rubric's [What counts as in focus](../task-reprioritize/ranking-rubric.md#what-counts-as-in-focus),
  which requires a quotable sentence and carries that quote into the ranking rationale.
  Do not restate the rule here; both skills read it from there so they cannot drift.
- **It outranks inference drawn from bucket placement**, including placement that focus
  itself drove. `/task-reprioritize` weights buckets by focus at each rebalance, so a
  bucket carries the focus *as it stood then*; this skill reads the focus as it stands
  now, and the fresher read wins (rubric § Focus weighting). The owner saying "this month
  is the importer" beats a task sitting in `now/` since March — and beats a task that
  last month's focus put there.
- The `**Not now:**` line lowers matching candidates. It does not delete them — a
  deprioritized task still appears under "Passed over", with the focus line as its reason,
  so the user can see the rule firing and override it.
- **No line in this file wins the ranking outright.** The focus document was deliberately
  reduced to direction only, so a task named in its prose is weighted like any other
  focus match, not selected. Where the last session left off is carried by the task
  document's own `## Resume point` and `status: in-progress` — in-flight pinning (Phase 4,
  step 1) is what surfaces it, and that signal is checked against startability rather than
  obeyed blindly.
- If the file still carries a `**Next action:**` line from before that change, treat it as
  **prose, and as possibly stale** — it may name work that is already done. Say in the
  output that you found one, that it no longer binds the ranking, and that the file wants
  a rewrite as direction.

### Constraint weighting

Fold `$ARGUMENTS` into the judgment; there is no lookup table, but the shape is:

| Constraint | Reads as |
|---|---|
| A duration ("30m", "an hour") | Prefer `effort: small`, and near-done in-flight work over anything that starts cold |
| Fatigue ("tired", "low energy") | Prefer mechanical, well-specified work; avoid Tier 3 (open questions) and category **L** |
| An exclusion ("no Unity", "no CMS") | Drop matching candidates from the ranking and list them under "Passed over" with the constraint as the reason |
| A subject ("something in the docs") | Treat as a temporary focus statement, layered over `focus.md` |

Always echo the constraint back and name what it changed. "Honored: 30m — this ranked
below `<other-task>` on value, and won because it is the only candidate that finishes in
one sitting" is the useful form; silently reordering is not.

---

## Phase 5 — Validate the top pick against HEAD

Only the top pick. Ranking the pool is cheap; verifying it is not, and verifying the
seven candidates you are not going to recommend is wasted work.

1. **Scope paths**: check every path in `## Scope` exists, minus the ones the task exists
   to create.
2. **Verification stamp**: if `finalized-at:` is present, confirm it resolves, then
   `git diff --stat <sha>..HEAD -- <scope paths>`. A non-empty diff means the ground moved
   under the brief — report how much, and how recently.

   **First check the repo actually tracks each Scope path.** `git diff <sha>..HEAD -- <path>`
   prints nothing and exits 0 when the path is untracked, gitignored, or lives in a
   different repository — the same output as "nothing changed." So the empty diff that
   means *validated* is indistinguishable from the empty diff that means *never looked*,
   and the pick gets recommended as verified on the strength of a check that ran on
   nothing. Guard it:

   ```bash
   git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || echo "not tracked here"
   ```

   Tasks that scope work into a sibling clone or a submodule are common — hq's own tasks
   name paths under `devtools/`, a separate clone that hq gitignores — so this fires often.
   Report an untracked Scope path as **unverifiable, not clean**: say which paths could not
   be checked and why, and treat the stamp as unconfirmed rather than confirmed. A pick may
   still be recommended on that basis; it may not be described as validated against HEAD.
3. **Strongest claims**: grep the two or three most absolute factual claims in the
   document ("nothing else calls X", "the only place that does Y", "N repos do Z"). Those
   are the claims that rot silently and are one `grep -rn` away from confirmation.

Read each command's own exit code and output; that *is* the verification. Where a check
is a deliberate probe whose failure you handle — `git cat-file -e <sha>^{commit}` on a
possibly-dangling stamp — `2>/dev/null` is fine. Nowhere else.

**If validation fails, do not recommend the task.** Surface it as stale: name exactly what
drifted, with the commits responsible, and recommend `/task-audit <task>` (to re-ground it)
or `/task-finalize <task>` (to re-verify and re-decide). Then fall through to the
next-ranked candidate and validate that one instead. Cap at three fall-throughs; if all
three are stale, report all three as stale — a queue whose top three briefs have rotted is
the finding, and recommending the fourth would bury it.

---

## Phase 6 — Present the recommendation

```
## Start this: <task title>

`<tasks>/<bucket>/<slug>.md` — status <status>, effort <effort>, <X/Y criteria done>

**Why now**: <2-4 sentences in plain language. What the task achieves, why it beats the
alternates today, and what makes it startable right now. No rubric jargon — "it is the
only piece of the CMS work that does not need a decision from you first" rather than
"category N, tier B".>

**Readiness**: <tier label> — <what that means for the next step>
**Validated at HEAD `<short-sha>`**: <what was checked and what it showed>
**Focus**: <how focus.md shaped this pick | "No focus document — ranked on mechanics alone">
**Constraint honored**: <the argument, and what it changed>   (omit when no argument)

### Alternates

1. **<title>** (`<bucket>/<slug>.md`) — <one line: why it is a close second, and what
   would have to be true for it to win instead>
2. **<title>** (`<bucket>/<slug>.md>`) — <same>

### Passed over

- **<title>** — <one line: the actual reason>
```

Report **Focus** and **Constraint honored** on every run, including the runs where they
had no effect ("focus document names the CMS; this pick is unrelated, and won on being
the only unblocked task") — a weighting input that is invisible when it does not fire is
indistinguishable from one that was never read.

"Passed over" is not optional and not a full listing. It covers the **obvious
contenders**: the next three by rank, every `priority: high` task that lost, every task
the focus document names that lost, every task demoted as gated (with its precondition
named — a gated task is usually the one that *looks* like it should have won, so its
absence from the top is what most needs explaining), and everything a blocker or the
constraint removed.
Give each a real reason. "Lower priority" is not a reason; "blocked on
`rotate-cloud-submodule-token`, which nobody has scheduled" is.

---

## Phase 7 — Close by offering the next command

Never invoke anything. End the turn in prose with one offer, chosen by the pick's tier:

- **Tier 1 (finalized)** — "Ready to work: `/task-implement <slug>`." Where that skill is
  not available in this repo, say the task is ready and stop.
- **Tier 2, 3, or 4** — "This needs `/task-finalize <slug>` first" — and say why in one
  clause: to settle the open questions, to write the acceptance criteria, or (Tier 2) to
  verify the brief against HEAD and stamp it. Offer the command; do not run it.

If the focus document was older than ~30 days, close with the question: "`focus.md` was
last touched <date> — is that still what matters?"

---

## When nothing is workable

An empty answer is a failed answer. If the pool is empty, or every candidate is blocked,
say what is true and what would change it — never "no tasks found" alone.

**No task files anywhere** — "`<tasks>/` holds no tasks in `now/`, `soon/`, or `later/`."
Offer `/task-create`. If `never/` holds tasks, say how many, and note they are excluded by
convention rather than by accident.

**Every candidate blocked** — print the blocked set as a table, then recommend the
unblocking work:

```
Nothing is workable right now. N candidates, all blocked:

| Task | Blocked on | Unblocking step |
|------|-----------|-----------------|
| <slug> | dependency `<other-slug>` (unfinished, in `soon/`) | Work `<other-slug>` first — it is unblocked |
| <slug> | `status: blocked` — "<reason quoted from the document>" | <the concrete step the reason implies> |
| <slug> | `## Scope` names `<path>`, which does not exist at HEAD | `/task-audit <slug>` — the brief has drifted |
```

Then make a recommendation anyway: if some blocker is itself a task in this repo, **that
task is the pick** — run it back through Phase 5 and present it normally, noting that it
was selected as the unblocker. If every blocker is external (waiting on a person, a
credential, an upstream release), name each one and say plainly that the queue needs new
work rather than more selection — offer `/task-create`.

**Every candidate gated** (rubric § Startability) — the same shape, with the gate in
place of the blocker: one row per candidate naming the precondition and what would
create it. Then recommend the precondition that frees the most candidates, as work in
its own right. Do not fall back to recommending a gated task without saying it is
gated; "start this, though you cannot" is the one answer worse than an empty one.

**`now/` empty but `soon/` or `later/` populated** is not this case; Phase 2 backfills.
Say the backfill happened and continue normally.

---

## See also

- [`ranking-rubric.md`](../task-reprioritize/ranking-rubric.md) — the shared ranking rules and the `<tasks>/focus.md` specification
- [`../task-reprioritize/SKILL.md`](../task-reprioritize/SKILL.md) — `/task-reprioritize`, which applies the same rubric to bucket placement
- [`../task-audit/SKILL.md`](../task-audit/SKILL.md) — `/task-audit <task>`, the depth-first pre-flight for a task this skill flagged as stale
- [`../task-finalize/SKILL.md`](../task-finalize/SKILL.md) — `/task-finalize`, the command this skill offers for anything below Tier 1
