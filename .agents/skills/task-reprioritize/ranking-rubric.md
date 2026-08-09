# Task ranking rubric

How to rank task documents against one another: area inference, in-flight pinning,
readiness and evidence signals, placement categories, area-coupling tiers, and
tiebreakers. Read this from `/task-reprioritize` (which ranks in order to shape
buckets) and from `/task-next` (which ranks in order to pick one task to start) —
it is the single source both consume, so the two cannot drift apart.

The file lives inside the `task-reprioritize` skill because that is where the rules
were written and proven, following the `_TEMPLATE.md` precedent (a canonical file
inside one skill, referenced across skill boundaries). It is a shared reference, not
a private one: edit it here and both skills change together.

## How each skill reads this document

| Skill | Question it asks | What a ranking decides |
|-------|------------------|------------------------|
| `/task-reprioritize` | Where does each task belong? | Which bucket the task is moved to |
| `/task-next` | Which single task should I start right now? | The order candidates are recommended in |

The sections below are written in the bucket vocabulary `/task-reprioritize` applies
literally. `/task-next` reads the same words as **strength, not as a move**:

| Rubric says | `/task-next` reads it as |
|-------------|--------------------------|
| Promote to `now/` | Rank near the top |
| Demote to `soon/` | Rank below the ordinary candidates |
| Flag for deletion | Do not recommend — this task looks finished; say so |
| Category **N** / **S** / **L** | Ready to start / a tier behind / plan before picking up |

Nothing in this document moves a file or edits one. Each skill decides what to do
with the ranking it produces.

---

## Area inference

Read the `## Scope` section and reduce each mentioned path to a coarse **area label**:

1. If `<tasks>/README.md` contains an **"Area map"** section (a repo-specific path-pattern → area table), use it — first matching pattern wins.
2. Otherwise, derive the label mechanically: strip the filename, take the first directory component of the path — and when that component is a generic container (`app`, `src`, `lib`, `packages`, `Assets`, `tests`, `docs`, `evals`, `features`), append the second component: `app/features/search/…` → `app/features` is still generic, so keep descending until the component is specific — `feature:search`-style granularity, i.e. the deepest component that names a subsystem rather than a container. Examples: `app/features/search/ranking.py` → `search`; `tests/unit/evals/` → `tests:evals`; `docs/planning/` → `docs`; `Assets/Scripts/Player/` → `Player`.

If a Scope section lists paths from **multiple** areas (common for cross-feature refactors), record all of them in order of frequency; the **primary area** is the first/most-mentioned.

If `## Scope` is missing or empty, derive the primary area from the title (e.g. `search` → the search feature, `eval` → evals, `test` → tests). Note this fallback explicitly in the rationale you print, so the user can correct it.

---

## In-flight pinning

**Pin in-flight tasks first**: if a task has any checked acceptance criteria (`- [x]`) OR status is `in-progress`, keep it in its current bucket regardless of category — the user is actively working on it and a demotion would be churn. Note these as "pinned (in-flight)" in the plan output. They still consume a slot toward the bucket's target count.

For a selector rather than a rebalancer, the same signal reads as: **an in-flight task
is presumptively the pick — resume beats start.** A task the owner abandoned mid-flight
is nearly always the right thing to return to, and picking up something new instead
leaves two half-done tasks.

---

## Readiness and evidence signals

These always override ordinary ranking.

> **`Created` in the tables below is derived, not stored.** Task documents carry **no
> `Created:` field** — it was removed fleet-wide in the 2026-07-26 format convergence,
> and "no dates in docs, tasks included" is a workspace rule. Read it from the file's
> first commit:
>
> ```bash
> git log --diff-filter=A --follow --format=%aI -- <task-file>
> ```
>
> Callers do not restate the command; take it from here so the two skills cannot drift
> on date format. `%aI` (author date, full ISO) is deliberate: it keeps sub-day
> resolution, so two tasks created the same day still tiebreak deterministically.
> `--follow` is what makes the date survive the `git mv` between buckets. Shorten for
> display if you like; compare on the full value.
>
> The 14-day threshold still measures what it always measured: the 2026-07-26
> convergence *modified* existing task files rather than recreating them, so
> `--diff-filter=A` dates were not rewritten. Verified against hq's queue — e.g.
> `tier2-non-cms-python-local-ci.md` reports first-commit `2026-06-09` with a last
> modification of `2026-07-30`.

| Signal | Action |
|---|---|
| Task outside `now/` with >50% acceptance criteria checked | Promote to `now/` regardless of shape |
| Task in `now/` with status `blocked` | Demote to `soon/` with note "blocked — revisit when unblocked" |
| Task in `now/` with **all** acceptance criteria checked | Flag for deletion (work appears complete) |
| Task in `now/` with status `not-started` and Created > 14 days ago | Tag as "stale `now/`"; don't auto-demote but call it out for the user |

And **evidence-based signals**, when a `/task-audit` run earlier in this conversation reported reprioritization signals (or dated audit notes are embedded in the documents):

| Signal | Action |
|---|---|
| Audit found all acceptance criteria met | Flag for deletion, citing the audit evidence |
| Core problem mostly solved | Demote (or flag for deletion), citing the evidence |
| Task blocks higher-priority work, or a listed dependency has landed | Promote to at least the blocked work's bucket |
| Documented parking/deferral rationale no longer holds | Promote for re-evaluation |
| Velocity work (developer experience, tooling, kaizen) | Place **at least in `soon/`, often `now/`** — accelerating development usually beats completing individual fixes or features |


---

## Startability

Whether a candidate's **remaining** work can begin in this session, without first
arranging something that does not exist yet.

This is not the same question as blocked, and conflating the two loses both. A
**blocked** task cannot proceed at all: `status: blocked`, an unmet dependency, a
`## Scope` naming paths the repo no longer has. A **gated** task is in perfect health
— sound brief, real Scope, criteria that make sense — and still cannot be started
today, because what is left of it needs a precondition nobody has arranged.

The signal is invisible in metadata. A gated task looks maximally ready: `status:
in-progress`, criteria partly checked, every Scope path present. It is found only by
reading what the *unchecked* criteria actually ask for.

| Gate | Reads as | Example |
|---|---|---|
| **Environment** | The remaining criteria need a repo state this repo does not have | A criterion covering queue-runner behavior, in a repo with no `<tasks>/queued/` bucket |
| **Occasion** | Only observable in a situation nobody can manufacture on demand | A criterion met only by landing a genuinely long session |
| **Upstream artifact** | Needs another task's output first | A skill that executes a prepared task, with no prepared task to execute |

### How it applies

- **It rebuts in-flight pinning.** That rule makes an in-flight task *presumptively*
  the pick, and this is the presumption's main rebuttal: a task can be in flight,
  furthest along in the pool, and still be the wrong recommendation because its
  remaining fifth cannot be started. Resume beats start — but only where resuming is
  possible.
- **It demotes; it never hides.** A gated task still appears under "Passed over",
  naming the specific precondition and what would clear it. The reader may know the
  gate has already lifted, or may decide to go create the precondition — neither is
  possible against silence.
- **Everything gated is a finding, not an empty result.** Where no candidate is
  startable, say so and recommend creating the precondition that frees the most work,
  in the same shape as the all-blocked answer.

### The guard

The precondition must be **nameable and concrete** — a repo state, an artifact, an
event someone could go cause. "Needs a `queued/` bucket this repo does not have" is a
gate. "Needs more thought", "I'd want to plan it first", "not the right moment" are
not: they are how *any* task can be reasoned out of contention, and a screen that can
disqualify anything ranks nothing. If you cannot name what would clear it, it is not
gated — fall through to the tiebreakers.

### Which skill applies it

`/task-next` applies it. `/task-reprioritize` does not: a gate is usually
**transient**, while a bucket is a statement about importance rather than about today. A
`now/` task gated on a missing precondition is not misplaced — `now/` still correctly
says it matters — and demoting it over a gate that clears next week is churn.
`/task-reprioritize` cites this document section by section and does not cite this one,
so its behavior is unchanged by the section existing.

That reasoning stands on its own. It used to be stated as shared with focus weighting,
which `/task-reprioritize` **now does apply** ([Focus
weighting](#focus-weighting-tasksfocusmd)) — the two cases part company on durability. A
focus statement is the owner's standing declaration of what the queue is for, revised
deliberately and rarely; a gate is a fact about one task that is expected to expire on
its own. Focus still honours the distinction this section draws: it never lifts a task
past one whose remaining work can actually start.

---

## Placement categories (N / S / L)

These categories encode the ranking intuition: narrow production tasks ship sooner; broad-or-support tasks queue behind them; infrastructure rewrites stay parked.

Read the `## Scope` section and apply the first matching rule. **"Production code"** means the repo's primary deliverable tree — whatever ships (`app/`, `src/`, a Unity project's `Assets/`, a library's package directory); **"support work"** means tests, evals, docs, scripts, and tooling around it.

| Category | Rule | Goes to |
|----|------|----|
| **N** (now-ready) | Scope touches production code **AND** the inferred primary areas reduce to one. Single-area production work, focused enough to start immediately. | `now/` |
| **S** (soon-ready) | Scope touches production code **with multiple primary areas** (cross-feature refactor, typing project, API+model change), **OR** Scope is exclusively support work (test-only, eval-only, docs-only). Production-broad or support work — valuable but a tier behind narrow production. | `soon/` |
| **L** (later-ready) | Scope adds or replaces a foundational system (a migration framework, build/deploy plumbing, startup orchestration, engine/framework version moves). Heuristic flags: new top-level directories combined with changes to the app's entry point, wholesale removal of foundational modules, mentions of `migrations/`-style scaffolding. Highest blast radius — these get planned, not picked up casually. | `later/` |

If a task doesn't fit any rule cleanly, default to **S** and note "(category ambiguous; defaulted to S)" in its rationale.

---

## Area-coupling tiers (A / B / C)

Within each category, order tasks by **area-coupling tier**. In repos without a queue, every task is Tier B unless it matches an `in-progress` task in `now/` (Tier C).

| Tier | Definition | Notes |
|---|---|---|
| **A** | Primary area matches a `queued/` task's area, OR the task explicitly references a queued task by filename | Promoting this primes follow-up work in the same area the autonomous worker is touching. |
| **B** | Primary area is distinct from every `queued/` task's area | Safe complement — no contention with in-flight work. |
| **C** | Primary area matches an `in-progress` task already in `now/` | Avoid clumping competing tasks in the same area. Last resort. |

---

## Tiebreakers

Within each tier, prefer (in order):
1. Higher progress fraction (in-flight > not-started — already underway).
2. Older Created date first (waited longer).
3. Smaller `effort` first (`small` before `medium` before `large`).

`Created` is derived from the file's first commit — see the definition under
[Readiness and evidence signals](#readiness-and-evidence-signals); do not look for a
frontmatter field, there is none.

**No git creation date** (file never committed): treat the task as oldest (created at epoch) — this avoids penalizing tasks for missing metadata.

---

## Focus weighting (`<tasks>/focus.md`)

A repo may state, in its owner's own words, what matters right now. That statement
lives at `<tasks>/focus.md` — the tasks root, beside `README.md`, deliberately outside
every bucket directory so no task glob mistakes it for a task.

**Both skills read it**, at two deliberately different cadences:

| Skill | When it reads focus | What focus decides there |
|-------|---------------------|--------------------------|
| `/task-reprioritize` | At each rebalance — **coarse and durable** | Which bucket a task sits in, so the queue's shape carries the stated direction between rebalances |
| `/task-next` | At every selection — **fine and live** | Which single task to start today, from whatever the buckets currently hold |

Applying it at both is not double-counting. Placement writes the direction into a
structure that then persists unattended; selection re-reads the direction as it stands
right now. **Where the two disagree, the selection-time read wins.** A bucket is a
snapshot of the focus as it was at the last rebalance, so the fresher read corrects the
staler one rather than compounding it: a task that focus lifted into `now/` last month,
which today's focus no longer covers, is ranked by `/task-next` on today's focus and
inherits no bonus from the bucket it was placed in.

- **No skill writes a next task into it.** `/session-land` records a session's resume
  point in the task document the work belongs to, not here; `/task-next` then surfaces
  it through in-flight pinning. See [Direction, not a next task](#direction-not-a-next-task).

### What counts as in focus

One rule, applied identically by both skills. It lives here precisely so the two cannot
drift on what "in focus" means.

A task is **in focus** when a **specific quotable sentence** of the focus prose covers
its **In brief**, `## Goal`, or `## Scope`. That is a semantic judgment made by reading
both documents — not a path match, not a label match — and the judgment carries its
evidence: the quoted fragment travels with it into `/task-reprioritize`'s plan table and
`/task-next`'s ranking rationale, so a reader can see *which sentence* fired.

Requiring the quote is what makes the rule work on real focus documents, which routinely
state conditions rather than areas. A focus saying that work elsewhere counts "exactly
when it unblocks this path" cannot be matched by extracting directory names from it; it
can be matched by reading a task and pointing at that clause. The requirement is also the
guard: if you cannot quote a sentence that covers the task, it is not in focus, however
plausible the association felt.

- **No citable sentence → out of focus, which is neutral.** Out of focus is the ordinary
  state of most of a queue. It carries no penalty — the task ranks on mechanics alone.
- **The `**Not now:**` line actively lowers** the tasks it names. That single line is the
  only part of the document that pushes down rather than merely failing to lift.

### How much focus weighs

**Focus modifies the mechanics; it never overrides them.** Every rule that already
decides an outcome keeps its full force — [Readiness and evidence
signals](#readiness-and-evidence-signals), [In-flight pinning](#in-flight-pinning), and,
for `/task-next`, [Startability](#startability). Focus never overturns the
blocked-in-`now/` demotion, never unpins in-flight work, and never lifts a task the
selecting skill has screened as unstartable. **It cannot promote a task whose remaining
work cannot start.**

What it does, in each place a ranking is formed:

- **Ordering within a placement category.** In-focus ranks above out-of-focus, applied
  *before* the coupling tiers and tiebreakers. Focus reorders the pool; it never moves a
  task between the N/S/L categories, which are decided by Scope alone.
- **Backfill preference.** Where `now/` is under-target and S candidates are pulled up,
  prefer in-focus ones, then area diversity.
- **Trim preference.** Where a bucket is over tolerance, trim out-of-focus tasks first.
- **The trim exemption.** A **blocked in-focus** task demoted out of `now/` lands in
  `soon/` and is **exempt from the onward trim to `later/`**. "Blocked — revisit when
  unblocked" is only useful if the task stays somewhere it will be looked at, and the
  focus statement is the evidence that it will be. Where the exemption leaves `soon/`
  over tolerance, report the deviation by name, exactly as in-flight pinning already
  does.

That exemption is the whole of focus's extra reach into placement, and it is deliberately
this small: **the shape targets themselves do not flex.** Focus decides which tasks fill
the shape, never how big the shape is.

**Say so when the focus is unworkable.** If every in-focus task is blocked (or, for
`/task-next`, gated), that is a finding and it must be reported in as many words: the
stated focus is currently unworkable. Do not paper over it by promoting blocked work on
the strength of its area. A queue that honestly reports "the thing you said matters
cannot be started" is more useful than one that merely looks aligned, and losing that
signal is the sharpest cost this weighting could carry.

### Churn

A rewritten focus is expected to move a handful of un-started tasks at the next
rebalance. That is the feature operating, not noise — buckets that track declared intent
have to move when the intent changes. The existing dampers bound it: in-flight pinning
holds started work in place, no-op reassignments are suppressed, a task promoted in a run
is not demoted again in the same run, and the weight-not-override design above keeps
focus away from anything the mechanics have an opinion about.

No hysteresis rule, deliberately. A damper for observed flapping can be added when
flapping is observed; adding one now would be tuning against a problem nobody has
measured.

### Format

```markdown
# Focus

<One to five sentences: what this repo is concentrating on right now, and why.
Plain prose, written by the owner — this is the one place stated intent beats
anything inferable from the queue.>

**Not now:** <optional, one unwrapped line — what is deliberately deprioritized, so a silence reads as a decision rather than an oversight.>
```

### Direction, not a next task

This file states a **direction**, at a level above any single task: the area, the kind
of work, the reason one kind comes before another. It does not name the next task, and
no skill writes one into it. Until 2026-08-03 the format carried a `**Next action:**`
line directly under the H1, written by `/session-land` and treated by `/task-next` as
an outright ranking win; it was removed because a focus document that names one task is
a task pointer wearing a strategy document's name — it goes stale the moment that task
is done, it overrides the ranking it was only meant to inform, and it competes with the
queue for the job the queue already does.

The resumption cost that line was answering is real (roughly 10–15 minutes to resume
after an interruption; Parnin, "Programmer, Interrupted"), so it is answered elsewhere
rather than dropped: the resume point belongs **in the task document**, which is where
the rest of that task's context already lives, and `/task-next` pins in-flight work
ahead of anything new. A next action written as prose in this file is therefore not a
contract with any skill — it is just prose, and a reader treats it as such.

### Rules a writer and a reader must both honor

- **No dates anywhere in the file.** Staleness comes from git (below). A written date
  goes stale the moment the prose is edited without touching it.
- `**Not now:**` is **optional and appears at most once**, with the label matched at the
  start of a line exactly as written. A writer **replaces** an existing line in place;
  when the label is absent it inserts one at the end. Never a second copy.
- **A writer never clobbers the prose.** The owner's statement and their `**Not now:**`
  line survive every automated write; only the labelled line being written changes. A
  writer creating the file from scratch uses this template.
- **Do not hard-wrap the labelled line.** It is one source line from the label to the
  newline, however long, so a writer can replace it without reflowing a paragraph and a
  reader can capture it without guessing where it ended. The surrounding prose wraps
  normally.
- Everything else is free prose. A reader must accept a file that carries no labelled
  line at all; prose alone is a valid focus document.
- **Rewrite in place.** No changelog, no accumulating list of past focuses — git holds
  the history. Keep the file under roughly 15 lines: it is read at the start of every
  selection, and a page of strategy is a different document.
- A workspace index repo (hq) may additionally name which *project* is in focus.

### Staleness

**Test that the file exists first, and only then ask git how old it is.** Absence is not
one of this command's output branches:

```bash
git log -1 --format=%cs -- <tasks>/focus.md
```

`git log` reports the last commit that *touched* a path, so for a focus document someone
deleted it exits 0 and prints an ordinary recent date (measured). A reader that skips the
existence test therefore gets a confident "focus is current" for a file that is not
there — the pass state reached by the very failure the check exists to detect. Stat the
file; then branch on the command's output:

- Date older than roughly 30 days → say so, ask whether the focus still holds, and
  **use it anyway**. A stale statement of intent still beats no statement.
- **Empty output is not a date.** That command exits 0 and prints nothing when the file
  exists but has never been committed. Treat empty as "not yet committed — staleness
  unknown" and say that; never let it read as fresh.
- File absent → say so out loud and rank on mechanics alone. Silent degradation is the
  failure mode to avoid: the user must never mistake a mechanics-only ranking for one
  that honored a focus they thought was being read.

**Both readers branch on all four cases, and both name the branch they took.** For
`/task-next` that shapes one recommendation; for `/task-reprioritize` it shapes an entire
pass, so an absent focus means the whole rebalance ran on mechanics and the report has to
say that where the focus findings would otherwise have gone. A placement pass degrades
exactly as visibly as a selection pass, or the queue silently stops honouring a document
the owner still believes is being read.

---

## See also

- [`SKILL.md`](SKILL.md) — `/task-reprioritize`, which applies this rubric to bucket placement (and carries the worked example that pins the rubric's behavior)
- [`../task-next/SKILL.md`](../task-next/SKILL.md) — `/task-next`, which applies this rubric to pick one task to start
- [`../task-create/_TEMPLATE.md`](../task-create/_TEMPLATE.md) — the canonical task template, the precedent for a shared file living inside one skill
