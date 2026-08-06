---
name: task-reprioritize
description: Rebalance the task queue toward a healthy shape in a single decide-then-apply pass
---

# Reprioritize Tasks

Rebalance the task queue toward the healthy shape defined in [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md) § Queue shape, in a single pass. Decide-then-apply instead of asking the user move-by-move: the plan is printed before any move, and staged changes are cheap to revert.

This command owns **all bucket moves and deletions** — `/task-audit` verifies what the documents say but never moves them. This skill is lightweight: it uses **task-file metadata and bucket state** — no codebase analysis, no test execution. When an `/task-audit` run earlier in this conversation produced reprioritization signals, consume them as evidence (see Phase 2); if the documents themselves look stale, run `/task-audit` first.

This skill **stages** changes via `git mv` / `git rm` but does **NOT** auto-commit.

**The ranking rules live in [`ranking-rubric.md`](ranking-rubric.md)**, next to this file — area inference, in-flight pinning, readiness and evidence signals, the N/S/L placement categories, the A/B/C coupling tiers, and the tiebreakers. `/task-next` reads the same rubric to pick a single task to start, so the two skills rank identically by construction. Read the rubric before Phase 1; the phases below cite its sections rather than restating them.

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below. If neither exists, print "No tasks directory found — run `/task-create` to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` (when it exists) holds tasks the autonomous runner is executing — read-only context for this skill, never a source or target of moves. In repos without it, skip everything that mentions it.
- **Bucket definitions**: [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md), relative to this skill's directory — what each bucket means and the shape target this skill enforces, shared with every other task skill so they cannot drift. If that path does not resolve (a repo whose `task-create` symlink is missing), read `devtools/.claude/skills/task-create/bucket-definitions.md` and say you fell back.
- **`never/` is excluded from rebalancing**: nothing is promoted out of or demoted into `never/` by shape rules. Parking and unparking are deliberate acts, via `/task-move`.

---

## Phase 1 — Inventory (including `queued/` as read-only context)

Glob for all `.md` files under:

- `<tasks>/now/`
- `<tasks>/soon/`
- `<tasks>/later/`
- `<tasks>/queued/` *(where it exists — read-only; these are executing, so they are not candidates for moves, only context for area-coupling)*

Exclude `README.md`, `_TEMPLATE.md`, anything inside `queued/blocked/`, and `.gitkeep`.

For each task, read the file and extract:

| Field | Source |
|------|--------|
| **Title** | The H1 title |
| **Status** | Frontmatter `status:` field (`not-started` / `in-progress` / `blocked`) |
| **Effort** | Frontmatter `effort:` field (`small` / `medium` / `large`) |
| **Priority** | Frontmatter `priority:` field (`high` / `medium` / `low`) |
| **Dependencies** | Frontmatter `dependencies:` list (task slugs that must land first) |
| **Created** | Derived from the file's first commit — [`ranking-rubric.md` defines the command](ranking-rubric.md#readiness-and-evidence-signals); there is no `Created:` field |
| **Goal** | First sentence of the `## Goal` (or `## Problem statement`) section |
| **Progress** | Count of `- [x]` vs total `- [ ]` + `- [x]` items inside `## Acceptance criteria`. Sentinel lines `<!-- AC:BEGIN -->` / `<!-- AC:END -->` inside the section are ignored. |
| **Area** | Inferred from `## Scope` — see "Area inference" below |
| **Related-task references** | Other task filenames mentioned in `## Scope`, `## Out of scope`, or `## References` |

### Area inference

Apply [`ranking-rubric.md` § Area inference](ranking-rubric.md#area-inference). It covers the repo's optional "Area map" table, the mechanical fallback that descends past generic container directories, multi-area Scope sections (the **primary area** is the most-mentioned), and the title-based fallback when `## Scope` is missing — which must be called out in the Phase 3 rationale so the user can correct it.

Print a compact inventory table grouped by bucket, including the queued section where present:

```
### Now (N) | Soon (N) | Later (N) | Queued (N, read-only)
| Bucket | Task | Status | Effort | Progress | Area | Goal (1 sentence) |
```

If `now/`, `soon/`, `later/` are all empty (and `queued/`, where present, is also empty), print "No tasks anywhere — nothing to rebalance." and stop.

---

## Phase 2 — Diagnose Bucket Shape

Compute current counts and compare to the **soft targets** [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md) § Queue shape defines, with the tolerances this skill adds:

| Bucket | Target | Tolerance |
|---|---|---|
| `now/` | 3 | over-target when count > 4; under-target when count < 3 |
| `soon/` | 3 | over-target when count > 4; under-target when count < 3 |
| `later/` | rest | no target — receives whatever's left |

Tolerance allows ±1 around the target so a 4-task `now/` is not noisily flagged. Beyond ±1, flag the bucket.

Also evaluate the **readiness signals** and the **evidence-based signals** in [`ranking-rubric.md` § Readiness and evidence signals](ranking-rubric.md#readiness-and-evidence-signals) — the first set read off the task documents themselves, the second off a `/task-audit` run earlier in this conversation (or dated audit notes embedded in the documents). Both sets always override bucket-shape moves; the rubric's Action column is written in this skill's bucket vocabulary and applies here literally.

Print a diagnosis block:

```
Current shape: now=N, soon=N, later=N (queued=N executing)
Targets:       now≈3, soon≈3, later=rest

Bucket health:
- now: <under-target by K | at-target | over-target by K>
- soon: <under-target by K | at-target | over-target by K>

Readiness/evidence overrides detected:
- <task>: <override action> (<reason>)
...

Queued context (read-only):
- <task> [area:<area>]
...
```

If shape is at-target AND no overrides apply, print "Queue is at-target — no moves." and stop.

---

## Phase 3 — Build the Rebalance Plan

This is the heart of the skill. Build **one** plan that satisfies hard rules, classifies each candidate by where it fits naturally, then places them into target buckets. Apply it as a single batch in Phase 4.

### Plan-building order

Apply these steps in order. After each step, recompute bucket counts so the next step sees the updated state.

#### Step 1 — Hard overrides

For each readiness or evidence signal from Phase 2:

- **>50% progress outside `now/`** → schedule a move to `now/`. Rationale: "in-flight (X/Y criteria done)".
- **Blocked in `now/`** → schedule a demote to `soon/`. Rationale: "status=blocked; revisit when unblocked".
- **All acceptance criteria checked in `now/`, or audit-confirmed complete** → schedule a deletion. Rationale: "all criteria met; flag for removal" (cite audit evidence where available).
- **Audit-backed promotion** (blocking work, landed dependency, invalidated parking rationale, velocity work) → schedule the promotion, citing the evidence.

These overrides override shape concerns. They run first so the rest of the plan sees the corrected state.

#### Step 2 — Classify each candidate by placement category

For each task currently in `now/`, `soon/`, or `later/` *not* claimed by a Step 1 override, assign a **placement category** per [`ranking-rubric.md` § Placement categories](ranking-rubric.md#placement-categories-n--s--l) — **N** (single-area production work) → `now/`, **S** (multi-area production, or support-only work) → `soon/`, **L** (foundational system change) → `later/`, defaulting to **S** with "(category ambiguous; defaulted to S)" when no rule fits cleanly.

Before categorizing, apply [`ranking-rubric.md` § In-flight pinning](ranking-rubric.md#in-flight-pinning): a task with any checked acceptance criteria or status `in-progress` stays in its current bucket regardless of category. Note these as "pinned (in-flight)" in the plan output. They still consume a slot toward the bucket's target count.

#### Step 3 — Sub-rank within each category by area-coupling and tiebreakers

Order the tasks in each category by the **area-coupling tier** in [`ranking-rubric.md` § Area-coupling tiers](ranking-rubric.md#area-coupling-tiers-a--b--c) — **A** (shares an area with a `queued/` task), **B** (distinct from every queued area), **C** (shares an area with an `in-progress` task already in `now/`). In repos without a queue, every task is Tier B unless it matches an `in-progress` task in `now/`.

Within each tier, apply [`ranking-rubric.md` § Tiebreakers](ranking-rubric.md#tiebreakers): higher progress fraction, then older creation date, then smaller `effort`.

#### Step 4 — Place into target buckets

- Take ranked N candidates, fill `now/` up to **3** slots. Surplus N tasks (rare) overflow to `soon/`.
- Take ranked S candidates, fill `soon/` up to **3** slots. Surplus S tasks fall to `later/`.
- All L candidates → `later/`.

If `now/` is under-target after N exhausted (e.g. only 2 N tasks exist), pull the top S candidates to backfill — prefer S candidates whose area doesn't already match a now-placed task. Note these as "(promoted from S — N pool short)" in the rationale.

If `soon/` is under-target after S exhausted, leave it under-target rather than dragging up infrastructure. Note the deviation: "soon/ under-target by K; only infra candidates remain."

#### Step 5 — Trim over-target buckets

If after Step 4 either bucket exceeds target + 1 (tolerance), demote bottom-ranked tasks from that bucket to the next bucket down. Bottom-ranked = lowest tier within category, then lowest progress, then largest effort. Do not demote a task that was just promoted in this same plan run (avoid promote-then-demote churn).

### Edge cases

- **Total task count too small**: e.g. only 4 tasks across now+soon+later. Use proportional targets: 2 in `now/`, 2 in `soon/`, 0 in `later/`. State the deviation explicitly: "Total tasks=4; treating target as now=2/soon=2."
- **Many tasks in `queued/`**: when `queued/` has ≥3 tasks (the autonomous worker is well-fed), it's fine to leave `now/` slightly under-target (2 instead of 3). Note this deviation explicitly.
- **No git creation date** (file never committed): the rubric's tiebreaker rule applies — treat the task as oldest.
- **Area inference fell back to title**: include "(area inferred from title)" in the rationale so the user can correct.
- **Task already in the right bucket per its category**: no move needed. Don't churn for no-op reassignments.

---

## Phase 4 — Apply the Plan

Print the full plan as a table **before** any move:

```
### Proposed rebalance plan (N moves)

| # | Task | From | To | Cat | Coupling | Rationale |
|---|------|------|----|-----|----------|-----------|
| 1 | normalize-imported-record-fixtures | later/ | now/ | N | B | single production area (data:fixtures); distinct from queued |
| 2 | replace-hand-rolled-schema-updates-with-migrations | soon/ | later/ | L | B | introduces a migration framework + startup change — infra rewrite |
| ...                                  | ...   | ...  | ... | ... | ... |
```

(`Cat` = placement category N/S/L from Step 2. `Coupling` = area-coupling tier A/B/C from Step 3.)

For each move, run:

```bash
git mv <tasks>/<source>/<task>.md <tasks>/<target>/<task>.md
```

For each deletion, run:

```bash
git rm <tasks>/<bucket>/<task>.md
```

Apply all moves directly. **Do not call `AskUserQuestion`.** If the user disagrees with the plan they can `git checkout` the staged changes — that's cheaper than a per-move round-trip.

If the plan is empty (shape is at-target and no overrides apply), print "Queue is at-target — no moves applied." and stop.

After applying, print:

```
Done. Final shape: now=N, soon=N, later=N.
Review the staged moves: `git status` then `git diff --staged --stat`.
Do **NOT** auto-commit. Commit when satisfied.
```

---

## Worked example

A synthetic queue that exercises every branch of the algorithm — an at-a-glance regression check when modifying this skill. The paths belong to an invented web app; the mechanics are repo-agnostic.

**Inventory:**

- `now/`: *(empty)*
- `soon/`: 1 task — `replace-hand-rolled-schema-updates-with-migrations.md`
- `later/`: 6 tasks —
  - `normalize-imported-record-fixtures.md`
  - `unify-the-two-model-construction-paths.md`
  - `decouple-annotation-tests-from-implementation.md`
  - `introduce-record-id-newtype.md`
  - `refactor-simulator-test-architecture.md`
  - `type-session-json-columns-against-schema-models.md`
- `queued/` (read-only): 3 —
  - `rebaseline-parser-fixtures-after-tokenizer-fix.md` (feature: parser)
  - `rework-task-reprioritize-skill.md` (meta: skills)
  - `tune-billing-proration-for-mid-cycle-upgrades.md` (feature: billing)

**Diagnosis:**

- now=0 → under-target by 3
- soon=1 → under-target by 2
- No readiness overrides (no >50% tasks outside `now/`; nothing blocked in `now/`).
- Queued areas: parser, skills, billing. No candidate task shares these areas — every candidate is Tier B (distinct, safe complement).

**Step 2 — Classify:**

| Task | Scope areas | Category | Rationale |
|------|------|---|---|
| `normalize-imported-record-fixtures` | `app/fixtures/imported_records/` | **N** | single production area |
| `unify-the-two-model-construction-paths` | `app/features/importer/...` (single area) | **N** | single production area |
| `decouple-annotation-tests-from-implementation` | `app/frontend/src/features/editor/components/annotations/...` | **N** | single production area (production + tests co-located) |
| `introduce-record-id-newtype` | `app/features/search/`, `app/features/reports/`, `app/features/editor/`, `app/api/` | **S** | multi-area production work |
| `type-session-json-columns-against-schema-models` | `app/models/`, `app/features/search/`, `app/features/importer/`, `app/features/schema/`, `app/api/` | **S** | multi-area production work |
| `refactor-simulator-test-architecture` | `tests/unit/evals/simulator/` only ("No production changes required") | **S** | test-only |
| `replace-hand-rolled-schema-updates-with-migrations` | `app/models/database.py`, new `migrations/` dir, `app/main.py`, docs | **L** | introduces a migration framework + startup change |

**Step 3 — Sub-rank within each category** (all Tier B; tiebreakers are progress → age → effort, but no task has progress and all are not-started, so it reduces to age → effort):

- **N**: 3 candidates, all fit in `now/`. Order doesn't matter — all promoted.
- **S**: 3 candidates, all fit in `soon/`. Order doesn't matter — all promoted.
- **L**: 1 candidate → `later/`.

**Step 4 — Place:**

- `now/` ← `normalize-imported-record-fixtures`, `unify-the-two-model-construction-paths`, `decouple-annotation-tests` ✓
- `soon/` ← `introduce-record-id-newtype`, `type-session-json-columns`, `refactor-simulator-test-architecture` ✓
- `later/` ← `replace-hand-rolled-schema-updates` ✓
- `replace-hand-rolled-schema-updates` was in `soon/` before; it gets demoted to `later/` by the category-L rule.

**Step 5 — Trim:** No over-target buckets.

**Final shape:** now=3, soon=3, later=1.

---

## Notes

- This skill replaces the older per-symptom heuristic that proposed one move at a time behind an `AskUserQuestion` round-trip. The single-pass, decide-then-apply design is intentional (and a recorded user preference): if the queue is misshapen by 3, the user should not have to answer 3 prompts — the plan is printed before moves so they can `git checkout` if they disagree.
- Frontmatter `dependencies:` is execution-order data (in queue repos, a dependent is never claimed before its dependency merges). This skill reads it as context but still infers *area* coupling from Scope paths.
