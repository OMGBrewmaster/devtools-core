---
name: task-finalize
description: Verify a task against HEAD, resolve its open questions interactively, write the recommended solution, validate readiness, and (in repos with a queue) optionally promote it to queued/ for the autonomous task-queue runner
---

# Finalize Task

Prepare a task for execution by a later session (or the autonomous runner): verify the task's claims against the codebase at HEAD, settle its open questions one at a time in conversation, record the resolutions in a `## Decisions` section, write a `## Recommended solution` where the analysis determines one, validate the task against the readiness rules, and — in repos with a queue — offer to `git mv` it into `<tasks>/queued/` so the task-queue runner picks it up.

**Run this on the strongest model available.** Finalization is the moment it earns its keep: this skill locks in the decisions and the design a later worker will execute, and a weak call here is inherited by every session that picks the task up. If you are on a weaker model, say so and offer to switch before Phase 2.5. (This was a `model:` frontmatter pin until 2026-08-09. It was dropped because the field is not in the Agent Skills spec — it fails validation and blocks the upload path — and because the pin was never observed to fire. An instruction reaches every harness; a vendor field reached one. The accepted loss: an unattended queue run gets whatever model the runner is configured with, with nobody present to read this.)

**Arguments**: `$ARGUMENTS` — optional task filename (with or without `.md`) or full path. If omitted, this skill scans for candidates and asks which to finalize.

## Repo conventions (resolve first)

- **Tasks root**: `docs/tasks/` if it exists, else `docs/planning/tasks/`. Written as `<tasks>/` below. If neither exists, print "No tasks directory found — run `/task-create` to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` exists only in repos running the autonomous task-queue runner. Where it is absent, Phase 5 is skipped entirely — finalization still leaves the task verified, decided, and stamped, which is its main value.

This skill **stages** changes (file edits, optionally `git mv`). Whether it then commits depends on what changed:

- **Self-contained run** — the only changes are the `## Decisions` edit, the `## Open questions` removal, and (optionally) the `git mv`. Everything in that diff was already shown to and confirmed by the user through the Phase 3 discussion — each decision restated as a `**Recording:**` line before the next question opened — so Phase 6 *offers to commit* with the message pre-filled.
- **Authored-content run** — the skill also created or substantially wrote content the user didn't see verbatim: follow-up task files spun off from a decision, a drift-corrected `## Context` or `## Scope` (Phase 2.5), a `## Recommended solution` (Phase 4b), multi-paragraph prose. That content was never shown in the discussion, so Phase 6 keeps the hard **review-before-commit** stop.

Track which case you're in as you go (see Phase 4f); Phase 6 branches on it.

---

## Phase 1 — Pick the Task

If `$ARGUMENTS` resolves to a real task file under `<tasks>/{now,soon,later,queued}/`, use it.

Otherwise:

1. Glob `<tasks>/{now,soon,later}/*.md`. Exclude `README.md` and `_TEMPLATE.md`.
2. For each file, parse the `## Open questions` section. A task is a **candidate** if either:
   - the Open questions section exists and has any non-comment, non-whitespace content, OR
   - the task fails any readiness rule from Phase 4 below.
3. If there are no candidates, print "No tasks need finalization — all readiness rules pass and Open questions sections are empty." and stop.
4. If there is one candidate, use it (print the chosen path).
5. If there are multiple candidates, use `AskUserQuestion` (single-select) to let the user pick one. Label format: `<bucket>/<task-name>`, description is a one-line goal summary.

Print the chosen task path before continuing.

---

## Phase 2 — Parse the Task

Read the task file end-to-end. Identify:

- The `## Open questions` block (may be absent, empty, or contain free-form content).
- The `## Out of scope` block (may be absent — relevant for placement of the new `## Decisions` section).
- Existing `## Decisions` section, if any (we'll append to it rather than duplicating).
- The YAML frontmatter fields: `status`, `effort`, `priority`, `dependencies`.

Extract individual **open questions** from the Open questions section as best you can. The section is free-form, so be flexible:

- Bullet/numbered list items → one question per item.
- Paragraphs separated by blank lines → one question per paragraph.
- A single block of prose with multiple `?` → split sensibly.
- HTML comments (`<!-- ... -->`) are guidance, not real questions — skip them.

If after extraction there are zero open questions but readiness still fails (Phase 4), skip Phase 3 — but do NOT skip Phase 2.5; verification runs on every finalize.

---

## Phase 2.5 — Verify the task against HEAD

The task document is a **cache of code observations made at some past commit**, and the codebase has moved since. Resolving open questions from the document's own premises risks locking in decisions against a stale worldview — and queuing a brief that instructs the worker to build something that already exists (or no longer applies). Verify first, then ask. **This phase is mandatory**, even when there are no open questions.

1. **Record the verification point**: `git rev-parse HEAD`. Phase 4c stamps this SHA into the frontmatter.
2. **Read every file the task cites** (in Context, Scope, and the open questions). For `file:line` references, confirm the cited construct is still there; where it moved, re-anchor by symbol + quote (see the drift rules below).
3. **Diff the task's vintage against HEAD**: find the task's creation date (`git log --diff-filter=A --format=%cs --follow -- <task-file> | tail -1`; fall back to dates in the task body), then `git log --oneline --since=<that-date>T00:00:00 -- <scoped paths>`. The `T00:00:00` is load-bearing: git completes a bare date with the **current clock time**, so without it a commit made earlier on the creation day falls outside the window — and the report reads exactly like "nothing has changed". Skim any commit that plausibly touches the task's claims.
4. **Spot-check the strongest factual claims** with grep — "X is never assigned", "nothing checks Y", "the only place that does Z". Absolute claims are exactly the ones that rot silently, and they are usually one `grep -rn` away from confirmation or refutation.
5. **Scale depth to `effort:`**: for `small`, reading the cited files suffices; for `medium`/`large`, also fan out an `Explore` subagent over the scoped subsystem so the verification isn't limited to the paths the (possibly stale) task happens to name.

Then act on what you found:

- **Rewrite `## Context` / `## Scope` so they are true at HEAD.** Say what changed and name the commits that changed it — the worker should inherit the corrected history, not rediscover it. Prefer **durable anchors** — a symbol name plus a short greppable quote (`` `run_tools`'s `if isinstance(result, Exception)` branch ``) — over bare line numbers, which rot fastest; keep line numbers only as a secondary convenience.
- **If verification answers or moots an open question, don't silently drop the question.** Carry the evidence into Phase 3a and let the user confirm the evidence-based resolution — the answer changed because the ground changed, and the user should see that.
- **Re-check `effort:` and `priority:`** against the corrected picture. If verification resized the task (machinery already landed; the problem grew), propose the change alongside the Phase 3 questions.
- Any rewrite in this phase makes the run **authored-content** (Phase 4f) — the user will review it before commit.

---

## Phase 3 — Resolve open questions by discussion

If there are zero open questions, skip this phase.

Open questions are settled **in conversation, one question per turn** — never by
collecting answers through an `AskUserQuestion` popup. A popup shows only the
question text and option labels: context is capped at a sentence per option, the
back-and-forth that actually changes decisions is impossible, and any briefing
posted in the same turn before the tool call renders as secondary status in the
console, visually displaced by the popup. A batched-popup mode shipped in this
skill's first version and was retired on first contact (2026-07-28): four design
decisions compressed into option labels was "not nearly enough context to make
an informed decision." `AskUserQuestion` remains in this skill only for genuine
pick-one or yes/no *capture* moments — choosing the task (Phase 1), the queue
move (Phase 5), the commit offer (Phase 6) — never for resolving an open
question.

### 3a — Discuss, one question per turn

For each open question, post one message containing:

1. **The question**, quoted from the task (trimmed, not paraphrased), and why it
   exists — what the decision impacts (cost, risk, scope, blast radius), in
   plain English, with paths where they help.
2. **Epistemic status**: what you **verified against code in Phase 2.5** versus
   what you are **assuming from the document**. If verification changed the
   question's premises or effectively answered it, lead with that evidence —
   "verified" versus "assumed" is the whole ballgame.
3. **The candidate answers**, each with genuine trade-off analysis — enough that
   the user could argue for any of them, not one-line labels.
4. **Your recommendation and its reasoning.**

Then **stop: end the turn in prose, no tool call after the context block**, so
the full picture is the last thing on screen and the user replies in the
conversation. This shape works on every surface, including Remote Control from
a phone, where each turn arrives as an ordinary readable message — keep the
block self-contained and skimmable on a small screen, and put the one-line task
summary in the first question's turn, since mobile shows no surrounding context.

Iterate until the question converges: answer follow-ups, sharpen or add
options, absorb corrections. Answers to earlier questions often reshape later
ones — that is the point of going one at a time; revise the later questions
before presenting them rather than presenting them as originally planned.

### 3b — Record each resolution

When a question converges, restate the outcome in a single line before opening
the next question:

> **Recording:** <the decision, in one or two sentences>

That line is the decision record — Phase 4a copies its text into `## Decisions`
verbatim, which is what lets a run stay **self-contained** (Phase 4f):
everything in the Decisions diff was shown to the user in the conversation. If
the user corrects a Recording line, re-issue it corrected; the last version
stands.

Special cases:

- The user answers in multi-paragraph prose worth preserving whole → mark it
  multi-paragraph for Phase 4 formatting and carry their words, not a summary.
- If the user explicitly says they want to defer a question, record the answer as `Deferred — left as open question.` and **keep** that question in the Open questions section. The task will fail readiness on it (Phase 4) and will not be moveable to `queued/` — that's intentional.

---

## Phase 4 — Apply Edits and Validate Readiness

### 4a — Write the Decisions section

Edit the task file:

1. Insert (or extend) a `## Decisions` section. Placement: immediately after `## Stopping conditions` and before `## Out of scope` (or at end of file if `## Out of scope` is absent). If the section already exists, append new entries to it.

2. Format each resolution as a single bullet:
   ```
   - **Q: <original question text>** — <the final **Recording:** line's text, verbatim>
   ```
   For multi-paragraph answers, use a sub-heading instead:
   ```
   ### <short version of the question>
   
   <user's multi-paragraph answer>
   ```

3. Remove the `## Open questions` section entirely **unless** any questions were marked Deferred — in that case, keep the section with just the deferred questions left in it.

### 4b — Write or update the Recommended solution

If the Phase 2.5 verification plus the resolved questions determine a concrete approach, write (or update) a `## Recommended solution` section. Placement: immediately after `## Context`, before `## Scope` (problem → design → footprint).

Rules for the section:

- **Advisory, not contract.** The acceptance criteria remain what the worker is graded on. The worker follows this design unless the code at HEAD contradicts it, and notes any deviation — the worker prompt states this; don't restate it in every task.
- **Ground every design point in what you verified.** Name the functions and files (durable anchors, per Phase 2.5), state why each piece goes where it goes, and flag any wrinkle the worker would otherwise trip on. The bar: a fresh session should be able to implement without re-deriving the analysis.
- **Skip it when it would be padding.** A task whose approach is obvious from Goal + acceptance criteria (mechanical rename, config flip, doc fix) doesn't need one — an empty design section is worse than none.

Writing or updating this section makes the run **authored-content** (Phase 4f): it will not be auto-committed.

### 4c — Stamp the verification point

Set `finalized-at: <sha>` in the YAML frontmatter — the HEAD SHA recorded at the start of Phase 2.5, overwriting any previous value. This records "the claims in this document were verified true as of this commit." The task-queue worker diffs `<sha>..HEAD` over the scoped paths at pickup time and re-verifies the brief when the diff is non-empty — briefs rot while sitting in `queued/`, and the stamp is what makes that rot detectable mechanically. (In repos without a queue the stamp serves the same purpose for whichever session picks the task up next.)

### 4d — Validate readiness rules

Check every rule and collect failures:

| # | Rule | How to check |
|---|------|--------------|
| 1 | Goal section non-empty and not a placeholder | `## Goal` block exists, has non-comment content, doesn't include the template placeholder text |
| 2 | At least one acceptance criterion listed | `## Acceptance criteria` contains ≥1 `- [ ]` or `- [x]` item whose text is not an angle-bracket placeholder (`<…>`, e.g. `<first acceptance criterion>`). Sentinel lines `<!-- AC:BEGIN -->` / `<!-- AC:END -->` inside the section are ignored when scanning for items. |
| 3 | Stopping conditions non-empty | `## Stopping conditions` exists, has non-comment content |
| 4 | Status field chosen | The frontmatter `status:` value is one of `not-started` / `in-progress` / `blocked`. Fails if the frontmatter block is missing or the value is the template placeholder (`<not-started \| in-progress \| blocked>`). |
| 5 | Effort field chosen | The frontmatter `effort:` value is one of `small` / `medium` / `large`. Fails if the value is the template placeholder (`<small \| medium \| large>`). |
| 6 | Open questions resolved | `## Open questions` is absent or contains only whitespace/comments |
| 7 | Priority and dependencies well-formed | The frontmatter `priority:` value is one of `high` / `medium` / `low`, and `dependencies:` is a (possibly empty) list of kebab-case task slugs — warn if a listed slug matches no existing task file or queue history. |
| 8 | Context verified at HEAD | The frontmatter `finalized-at:` value is a valid commit SHA in this repo (`git cat-file -e <sha>^{commit}`). Stamped by Phase 4c; fails if absent or dangling — a task without it was never verified. |

### 4e — Report

Print a readiness summary:

- ✅ rules passed
- ❌ rules failed, each with the specific reason
- ⚠️ **no `**In brief**:` paragraph, or it still holds the template comment** — warn,
  do not fail. In brief serves human triage, not worker correctness, so a missing one
  never blocks `queued/`; tasks predating the field are expected to lack it. Offer to
  write one, and if the user accepts, note that authoring it makes this an
  **authored-content** run (4f) — so it will not be auto-committed.

### 4f — Classify the run

Decide whether this is a **self-contained run** or an **authored-content run** (definitions in the skill intro):

- If the *only* edits you made are the `## Decisions` section, the `## Open questions` removal, the `finalized-at:` stamp (deterministic, machine-checkable — it never makes a run authored-content), and (pending Phase 5) the `git mv` — it's **self-contained**. Note that multi-paragraph answers the user typed are still self-contained: they're the user's own words, shown in the conversation.
- If you created any new file, or substantially authored prose the user never saw verbatim — a drift-corrected `## Context` or `## Scope` (Phase 2.5), a `## Recommended solution` (Phase 4b), spun-off follow-up task files — it's **authored-content**.

Carry this classification into Phase 6.

---

## Phase 5 — Offer to Move to queued/

**Skip this phase entirely in repos without `<tasks>/queued/`.**

If **any** readiness rule failed, print:

> Task is not yet ready for `queued/`. Fix the failures above and re-run `/task-finalize`, or leave it in its current bucket.

…and skip the move.

If all rules pass, use `AskUserQuestion` to ask:

- **question**: "Move `<task-name>.md` to `queued/` now? The autonomous task-queue runner picks up tasks at main's HEAD — the runner won't see this task until you also commit the rename."
- **header**: "Move to queued"
- options:
  - `Yes — move to queued/` (Recommended)
  - `No — leave in <current bucket>`

If the user picks Yes, run:

```bash
git add <tasks>/<source-bucket>/<task-name>.md \
  && git mv <tasks>/<source-bucket>/<task-name>.md <tasks>/queued/<task-name>.md
```

The `git add` first is important: a freshly-created task may still be untracked, and `git mv` errors on untracked sources (`fatal: not under version control`). Staging the source first makes the rename work for untracked, tracked-clean, and tracked-modified files alike.

If the task is already in `queued/`, skip the move and note "Task is already in queued/."

---

## Phase 6 — Summary and Commit

Print a final block with:

- The task path (post-move).
- The Phase 2.5 verification result: what had drifted and was corrected (with the commits responsible), or "no drift found". Name the `finalized-at` SHA.
- Number of open questions resolved.
- Whether any were deferred (and which).
- Whether a `## Recommended solution` was written or updated.
- Readiness check result.
- Whether the task was moved, and from/to which bucket (queue repos only).
- The run classification from Phase 4f (self-contained vs authored-content).

Pick the commit message:

```
docs(tasks): finalize <task-name> for autonomous execution
```
…or, if no move happened:
```
docs(tasks): resolve open questions on <task-name>
```

Then branch on the Phase 4f classification:

### Self-contained run — offer to commit

Every staged change was confirmed through the Phase 3 discussion, so use `AskUserQuestion` to offer the commit (a yes/no capture — exactly what the popup is for):

- **question**: "Commit the staged changes now with message `<chosen message>`?"
- **header**: "Commit"
- options:
  - `Yes — commit now` (Recommended)
  - `No — leave staged for review`

If the user picks Yes, run `git commit -m "<chosen message>"` and report the resulting commit hash. If No, print the review reminder below.

After a Yes in a repo whose AGENTS.md documents a docs-only shipping convention (a "Shipping docs-only changes" section naming a predicate script), offer to push too — from a local session: run the predicate script against the remote default branch (e.g. `scripts/docs-only-diff.sh origin/main`); exit 0 → push directly to the default branch and read the push's own output as the verification; any other exit → name what else the outgoing range carries and leave the commit local. From a cloud session, `/ship` carries docs-only PRs to merge without a review pause (maintainer's standing delegation, 2026-07-29).

### Authored-content run — do NOT auto-commit

The diff includes files or prose the user never saw verbatim. Do **not** offer to commit. Print:

> Do **NOT** auto-commit. This run authored content beyond the confirmed discussion (<name the files/prose>). Review the staged changes (`git status`, `git diff --staged`) and commit when satisfied.

### Review reminder (both cases, when not committed)

> Review the staged changes (`git status`, `git diff --staged`) and commit when satisfied. (Queue repos: the autonomous task-queue runner watches main's HEAD, not the working tree — until you commit the rename, the runner cannot see this task.)
