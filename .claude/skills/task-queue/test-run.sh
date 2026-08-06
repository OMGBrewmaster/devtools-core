#!/usr/bin/env bash
# Unit tests for the parallel-safety and lifecycle primitives in run.sh:
#
#   claim_next_task                       — lock-skipping task pickup, so
#                                           sibling runners claim different
#                                           tasks instead of colliding on
#                                           the first eligible one.
#   task_priority_rank / task_dependencies — frontmatter parsing for the
#                                           claim path's priority ordering
#                                           and dependency filtering.
#   list_eligible_tasks (real git)        — end-to-end eligibility against
#                                           a scratch repo: priority order,
#                                           dependency blocking/unblocking,
#                                           marker skipping.
#   validate_worker_state (real git)      — the success-path signal-
#                                           disagreement probe behind the
#                                           .partial marker.
#   acquire_main_lock / release_main_lock — re-entrant host-wide lock that
#                                           serializes every write to
#                                           `main` across runners.
#   request_stop / should_stop            — the signal-flag graceful stop:
#                                           the handler only RECORDS a stop
#                                           request; the loop acts on it at
#                                           its iteration boundary.
#   runner_alive_for_slug                 — the reconcile liveness probe:
#                                           a slug whose claim lock can be
#                                           re-acquired has no live runner.
#   ci_slug_from_merge_subject /          — the CI auto-fix loop's pure
#   ci_fp_attempts / ci_record_fp_attempt   primitives: merge-subject slug
#   / ci_disposition_for_fp                 extraction, fingerprint attempt
#                                           counting, and the dispatch /
#                                           skip / escalate / done decision.
#   the source guard (both runners)       — loading a run.sh defines its
#                                           functions and does nothing else,
#                                           whatever the LOADER's positional
#                                           parameters happen to be. Covers
#                                           audit-queue too: the mirror
#                                           assertion below diffs function
#                                           bodies with `sed` and never
#                                           sources the sibling.
#
# These exercise the REAL functions from run.sh. run.sh is sourced — its
# source-guard skips the polling loop — and only list_eligible_tasks (the
# git-query boundary) is stubbed, so pickup can be driven with a
# controlled candidate list. No git repo, no `claude`, no network: the
# whole suite runs in well under a second.
#
# A "sibling runner is working task X" is simulated by holding X's lock
# file on a dedicated fd inside this process. flock denies a second
# exclusive lock on the same file even from the same process via a
# different fd — exactly the conflict claim_next_task's `flock -n 9`
# relies on — so this is a faithful, and far simpler, proxy for a
# separate runner process. (Verified: a cross-process probe is also used
# for the main-lock tests below.)
#
# Usage:  bash test-run.sh
# Exit 0 = all passed, 1 = a failure (or a syntax error in run.sh).

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- syntax gate -----------------------------------------------------
if ! bash -n "$SKILL_DIR/run.sh"; then
  echo "FAIL: run.sh has a syntax error"
  exit 1
fi

# ---- load the runner's functions (loop skipped by the source-guard) --
# shellcheck source=/dev/null
source "$SKILL_DIR/run.sh"
trap - INT TERM HUP   # the runner registers its trap only in the
                      # executed (non-sourced) section, so nothing is
                      # actually set here — this is belt-and-suspenders.

# ---- scaffolding -----------------------------------------------------
TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

# Point the lock primitives and the stop sentinel at a throwaway dir.
LOCK_DIR="$TESTROOT/locks"
MAIN_LOCK_FILE="$LOCK_DIR/main.lock"
STOP_SENTINEL="$TESTROOT/stop"
mkdir -p "$LOCK_DIR"

PASS=0
FAIL=0
SKIP=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $1"
    echo "          expected: $2"
    echo "          actual:   $3"
    FAIL=$(( FAIL + 1 ))
  fi
}

# Declare coverage this repo cannot exercise. Used only for the audit-queue
# mirror assertions: that sibling runner ships in one repo only, so in a repo
# carrying task-queue alone the property is vacuous rather than violated.
#
# It is a counted, printed SKIP and never silence, because the summary is the
# only place a reader learns the mirror went unchecked — a quiet `continue`
# would let "106 passed, 0 failed" mean two different things depending on
# which repo ran it, which is the decorative-check failure this suite calls
# out at the source-guard block below (see docs/signal-hygiene.md).
skip() {  # skip <description> <reason>
  echo "  SKIP  $1"
  echo "          reason:   $2"
  SKIP=$(( SKIP + 1 ))
}

# Hold / release a lock file on a caller-chosen fd, standing in for a
# sibling runner that currently holds (or has finished) that task.
hold_lock()    { eval "exec $1>\"$2\""; flock -n "$1"; }   # <fd> <lockfile>
release_lock() { eval "exec $1>&-"; }                      # <fd>

# "free" if some OTHER process could still grab the file lock, else "held".
# Uses a separate `flock` process — a genuine cross-process probe.
lock_state() { flock -n "$1" -c true 2>/dev/null && echo free || echo held; }

# Release the per-task lock claim_next_task leaves held on fd 9.
release_fd9() { flock -u 9 2>/dev/null; exec 9>&- 2>/dev/null || true; }

# ---- frontmatter parsing: task_priority_rank / task_dependencies -----
echo "task_priority_rank / task_dependencies — frontmatter parsing"

check "priority: high ranks 0" "0" "$(printf 'priority: high\n' | task_priority_rank)"
check "priority: medium ranks 1" "1" "$(printf 'priority: medium\n' | task_priority_rank)"
check "priority: low ranks 2" "2" "$(printf 'priority: low\n' | task_priority_rank)"
check "absent priority defaults to medium" "1" "$(printf 'effort: small\n' | task_priority_rank)"
check "unrecognised priority defaults to medium" "1" "$(printf 'priority: urgent\n' | task_priority_rank)"
check "trailing comment on priority is stripped" "0" \
  "$(printf 'priority: high   # jump the queue\n' | task_priority_rank)"

deps_csv() { task_dependencies | paste -sd, -; }
check "inline empty dependency list parses as none" "" \
  "$(printf 'dependencies: []\n' | deps_csv)"
check "inline dependency list parses" "dep-a,dep-b" \
  "$(printf 'dependencies: [dep-a, dep-b]\n' | deps_csv)"
check "block dependency list parses (quotes stripped)" "dep-c,dep-d" \
  "$(printf 'dependencies:\n  - dep-c\n  - "dep-d"\n' | deps_csv)"
check "no dependencies key parses as none" "" \
  "$(printf 'priority: high\n' | deps_csv)"

# ---- list_eligible_tasks: real-git scratch queue ----------------------
echo
echo "list_eligible_tasks — priority order + dependency DAG (scratch git repo)"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

REPO="$TESTROOT/repo"
QREL="$QUEUE_REL"   # match whatever tasks root the sourced run.sh detected
mkdir -p "$REPO/$QREL/blocked"
git -C "$REPO" init -q -b main

mk_task() {  # <name> <priority> [deps-inline]
  {
    printf -- '---\nstatus: not-started\neffort: small\npriority: %s\ndependencies: %s\n---\n\n# %s\n' \
      "$2" "${3:-[]}" "$1"
  } > "$REPO/$QREL/$1.md"
}

mk_task aaa-low low
mk_task bbb-dependent high "[dep-done]"
mk_task ccc-blocked-dep high "[dep-pending]"
mk_task ddd-phantom-dep high "[never-queued-slug]"
mk_task eee-crashed-dep high "[dep-crashed]"
mk_task mmm-high high
mk_task nnn-high high
mk_task dep-pending medium
mk_task dep-done medium
mk_task dep-crashed medium
printf '# no frontmatter\n' > "$REPO/$QREL/fff-bare.md"
printf '# readme\n' > "$REPO/$QREL/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "seed queue"
# dep-done completes: brief removed from queued/ (the runner's rm commit).
git -C "$REPO" rm -q "$QREL/dep-done.md" && git -C "$REPO" commit -qm "task-queue: merge dep-done"
# dep-crashed fails: forensic marker rename stays in the tree.
git -C "$REPO" mv "$QREL/dep-crashed.md" "$QREL/dep-crashed.crashed.20260611-101010.md" \
  && git -C "$REPO" commit -qm "task-queue: mark dep-crashed as crashed"

OLD_ROOT="$ROOT"
ROOT="$REPO"

eligible_basenames() { list_eligible_tasks | sed "s#^$ROOT/$QREL/##; s#\.md\$##" | paste -sd, -; }

# Expected: high-priority tasks first (alphabetical within priority);
# bbb-dependent eligible (dep-done left the queue tree and was once
# queued); ccc/ddd/eee blocked (dep still queued / never queued / marker
# in tree); bare-frontmatter file defaults to medium; README and the
# crashed marker skipped.
check "orders by priority then alphabetical; blocks unmet dependencies" \
  "bbb-dependent,mmm-high,nnn-high,dep-pending,fff-bare,aaa-low" \
  "$(eligible_basenames)"

# Completing the pending dependency unblocks its dependent.
git -C "$REPO" rm -q "$QREL/dep-pending.md" && git -C "$REPO" commit -qm "task-queue: merge dep-pending"
check "a dependent becomes claimable once its dependency leaves the queue" \
  "bbb-dependent,ccc-blocked-dep,mmm-high,nnn-high,fff-bare,aaa-low" \
  "$(eligible_basenames)"

# A dependency moved to blocked/ still blocks its dependent.
git -C "$REPO" mv "$QREL/dep-crashed.crashed.20260611-101010.md" "$QREL/blocked/dep-crashed.md" \
  && git -C "$REPO" commit -qm "move to blocked/"
if printf 'dependencies: [dep-crashed]\n' | task_deps_satisfied; then
  RESULT="satisfied"
else
  RESULT="blocked"
fi
check "a dependency parked in blocked/ still blocks" "blocked" "$RESULT"

# ---- validate_worker_state: success-path signal disagreement ----------
echo
echo "validate_worker_state — the .partial probe (scratch git worktree)"

WT="$TESTROOT/wt"
mkdir -p "$WT/$QREL"
git -C "$WT" init -q -b main
printf '# brief\n' > "$WT/$QREL/test-task.md"
git -C "$WT" add -A && git -C "$WT" commit -qm "start"
WT_START="$(git -C "$WT" rev-parse HEAD)"

validate_verdict() {  # <worktree> <task-rel> <start-sha>
  if validate_worker_state "$1" "$2" "$3" >/dev/null; then echo ok; else echo "$VALIDATE_FAILURE"; fi
}

git -C "$WT" commit -q --allow-empty -m "work"
check "a brief still on disk fails validation" \
  "brief still present in the worktree (queue-file git rm failed?)" \
  "$(validate_verdict "$WT" "$QREL/test-task.md" "$WT_START")"

git -C "$WT" rm -q "$QREL/test-task.md" && git -C "$WT" commit -qm "rm brief"
check "no commits beyond START_SHA fails validation" \
  "no commits beyond START_SHA on the task branch" \
  "$(validate_verdict "$WT" "$QREL/test-task.md" "$(git -C "$WT" rev-parse HEAD)")"

touch "$WT/STUCK.md"
check "a leftover STUCK.md fails validation" \
  "leftover STUCK.md in the worktree" \
  "$(validate_verdict "$WT" "$QREL/test-task.md" "$WT_START")"
rm -f "$WT/STUCK.md"

check "clean state passes (collect probe skipped without a .venv)" \
  "ok" "$(validate_verdict "$WT" "$QREL/test-task.md" "$WT_START")"

# A fake .venv python stands in for pytest: exit 1 = broken collection.
mkdir -p "$WT/.venv/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WT/.venv/bin/python"
chmod +x "$WT/.venv/bin/python"
check "a failing pytest collect probe fails validation" \
  "pytest --collect-only failed (unimportable tree or broken test collection)" \
  "$(validate_verdict "$WT" "$QREL/test-task.md" "$WT_START")"

printf '#!/usr/bin/env bash\nexit 0\n' > "$WT/.venv/bin/python"
check "a passing pytest collect probe passes validation" \
  "ok" "$(validate_verdict "$WT" "$QREL/test-task.md" "$WT_START")"

ROOT="$OLD_ROOT"

# ---- claim_next_task: lock-skipping pickup ---------------------------
echo
echo "claim_next_task — lock-skipping pickup"

# Stub the git-query boundary with a fixed three-task queue.
list_eligible_tasks() {
  printf '%s\n' \
    "$TESTROOT/queued/alpha.md" \
    "$TESTROOT/queued/bravo.md" \
    "$TESTROOT/queued/charlie.md"
}

# Stub the HEAD-presence check — the synthetic queue above is not in git.
# Overridden in the TOCTOU test below to simulate a task vanishing.
task_at_head() { return 0; }

TASK_FILE=""; SLUG=""
claim_next_task
check "claims the first task when nothing is locked" "alpha" "${SLUG:-<none>}"
release_fd9

hold_lock 50 "$LOCK_DIR/alpha.lock"          # sibling working 'alpha'
TASK_FILE=""; SLUG=""
claim_next_task
check "skips a sibling-locked task, claims the next" "bravo" "${SLUG:-<none>}"
release_fd9

hold_lock 51 "$LOCK_DIR/bravo.lock"          # sibling also working 'bravo'
TASK_FILE=""; SLUG=""
claim_next_task
check "skips two locked tasks, claims the third" "charlie" "${SLUG:-<none>}"
release_fd9

hold_lock 52 "$LOCK_DIR/charlie.lock"        # all three now held
TASK_FILE=""; SLUG=""
if claim_next_task; then RESULT="claimed-${SLUG}"; else RESULT="none-available"; fi
check "reports failure when every eligible task is locked" "none-available" "$RESULT"
release_fd9

release_lock 50; release_lock 51; release_lock 52   # siblings finish
TASK_FILE=""; SLUG=""
claim_next_task
check "claims the first task again once locks are released" "alpha" "${SLUG:-<none>}"
release_fd9

# TOCTOU close: a task whose lock we win but which has vanished from
# HEAD (a sibling merged it in the claim window) is skipped, not claimed.
task_at_head() { [[ "$1" != *"/alpha.md" ]]; }   # alpha no longer at HEAD
TASK_FILE=""; SLUG=""
claim_next_task
check "skips a task that vanished from HEAD after its lock was won" \
  "bravo" "${SLUG:-<none>}"
release_fd9
task_at_head() { return 0; }                     # restore

# ---- acquire_main_lock / release_main_lock ---------------------------
echo
echo "acquire_main_lock / release_main_lock — re-entrant host-wide lock"

MAIN_LOCK_HELD=0

check "main lock is free before any acquire" "free" "$(lock_state "$MAIN_LOCK_FILE")"

acquire_main_lock
check "depth counter is 1 after one acquire" "1" "$MAIN_LOCK_HELD"
check "main lock is held against other processes after acquire" \
  "held" "$(lock_state "$MAIN_LOCK_FILE")"

# Nested acquire — the case mark_queue_file hits inside the merge block.
acquire_main_lock
check "depth counter is 2 after a nested acquire (no self-deadlock)" \
  "2" "$MAIN_LOCK_HELD"

release_main_lock
check "depth counter is 1 after the inner release" "1" "$MAIN_LOCK_HELD"
check "main lock still held after only the inner release" \
  "held" "$(lock_state "$MAIN_LOCK_FILE")"

release_main_lock
check "depth counter is 0 after the outer release" "0" "$MAIN_LOCK_HELD"
check "main lock is free again after the outer release" \
  "free" "$(lock_state "$MAIN_LOCK_FILE")"

# ---- request_stop / should_stop: signal-flag graceful stop -----------
echo
echo "request_stop / should_stop — signal-flag graceful stop"

# "stop" if a graceful stop is pending at an iteration boundary, else "go".
stop_verdict() { if should_stop; then echo stop; else echo go; fi; }

STOP_REQUESTED=0
FAST_STOP=0
rm -f "$STOP_SENTINEL"
check "no stop pending before any request" "go" "$(stop_verdict)"

# First signal: the handler RECORDS the request — it must not exit.
request_stop >/dev/null
check "first request_stop records a graceful stop" "stop" "$(stop_verdict)"
check "first request_stop does NOT escalate to fast stop" "0" "$FAST_STOP"
check "the runner process is still alive after request_stop (handler returned)" \
  "alive" "alive"

# Second signal: escalates to a fast stop.
request_stop >/dev/null
check "second request_stop escalates to fast stop" "1" "$FAST_STOP"
check "a fast stop is still a pending stop at the boundary" "stop" "$(stop_verdict)"

# The global stop sentinel is an independent trigger — no signal needed.
STOP_REQUESTED=0
FAST_STOP=0
check "no stop pending once the signal flag is cleared" "go" "$(stop_verdict)"
: > "$STOP_SENTINEL"
check "the stop sentinel alone makes should_stop fire" "stop" "$(stop_verdict)"
rm -f "$STOP_SENTINEL"
check "removing the sentinel clears the stop again" "go" "$(stop_verdict)"

# ---- runner_alive_for_slug: reconcile liveness probe -----------------
echo
echo "runner_alive_for_slug — reconcile liveness probe"

# "alive" if a live runner holds the slug's claim lock, else "free".
alive_verdict() { if runner_alive_for_slug "$1"; then echo alive; else echo free; fi; }

check "a slug with no lock file at all has no live runner" \
  "free" "$(alive_verdict "never-claimed")"

# A live runner is simulated by holding the slug's lock on a dedicated fd.
hold_lock 55 "$LOCK_DIR/live-slug.lock"
check "a slug whose claim lock is held reads as a live runner" \
  "alive" "$(alive_verdict "live-slug")"

release_lock 55
check "once the lock is released the slug reads as an orphan (no live runner)" \
  "free" "$(alive_verdict "live-slug")"

# Probing must not itself leave the lock held — a real claim must still win.
check "probing left the lock free for a real claim" \
  "free" "$(lock_state "$LOCK_DIR/live-slug.lock")"

# ---- CI auto-fix primitives ------------------------------------------
echo
echo "ci_slug_from_merge_subject — merge-subject slug extraction"

check "extracts the slug from a normal merge subject" \
  "add-widget-export" \
  "$(ci_slug_from_merge_subject 'task-queue: merge add-widget-export')"

check "extracts the slug from a recovered-orphan merge subject" \
  "add-widget-export" \
  "$(ci_slug_from_merge_subject 'task-queue: merge recovered orphan add-widget-export')"

echo
echo "ci_fp_attempts / ci_record_fp_attempt / ci_disposition_for_fp"

# Point the fingerprint store at a throwaway dir; stub the one git-query
# boundary (is a fix for this fingerprint already in the queue tree?).
CI_FP_DIR="$TESTROOT/ci-fp"
CI_FIX_MAX_ATTEMPTS=2
mkdir -p "$CI_FP_DIR"
FP_IN_QUEUE=0
ci_fp_in_queue_at_head() { (( FP_IN_QUEUE )); }

check "a never-seen fingerprint has zero attempts" "0" "$(ci_fp_attempts aabbcc11)"
check "a never-seen fingerprint dispatches a follow-up" \
  "dispatch" "$(ci_disposition_for_fp aabbcc11)"

ci_record_fp_attempt aabbcc11
check "recording an attempt increments the count" "1" "$(ci_fp_attempts aabbcc11)"
check "one attempt in, recurrence still dispatches" \
  "dispatch" "$(ci_disposition_for_fp aabbcc11)"

# A queued (or in-flight, or blocked) follow-up suppresses re-dispatch
# regardless of the count.
FP_IN_QUEUE=1
check "a fingerprint whose fix is already queued is skipped" \
  "skip" "$(ci_disposition_for_fp aabbcc11)"
FP_IN_QUEUE=0

ci_record_fp_attempt aabbcc11
check "attempt count reaches the maximum" "2" "$(ci_fp_attempts aabbcc11)"
check "a fingerprint at max attempts escalates" \
  "escalate" "$(ci_disposition_for_fp aabbcc11)"

# After escalation (marker committed, .escalated flag written), later
# recurrences are the operator's problem — the loop stays hands-off.
: > "$CI_FP_DIR/aabbcc11.escalated"
check "an escalated fingerprint that recurs is left to the operator" \
  "done" "$(ci_disposition_for_fp aabbcc11)"

# Re-arming: clearing the fingerprint state restores dispatch.
rm -f "$CI_FP_DIR/aabbcc11.count" "$CI_FP_DIR/aabbcc11.escalated"
check "clearing fingerprint state re-arms dispatch" \
  "dispatch" "$(ci_disposition_for_fp aabbcc11)"

# ---- check_stall_signature: the backgrounded-work gate ---------------
echo
echo "check_stall_signature — background-work gate over fabricated daemon state"

# Regression cover for the 2026-07-31 incident: a worker that backgrounds a
# long command (the worker prompt REQUIRES it for commits) gets an instant
# "running in background" tool_result, ends its turn to await the completion
# notification, and sits at state=working tempo=idle. Every timing signal in
# check_stall_signature reads that as a stall, so the runner `claude stop`ped
# a healthy worker mid-commit. The discriminator is the daemon's inFlight
# counter. The state.json shapes below are transcribed from a live probe
# (2026-07-31, Claude Code 2.1.220, three sequential 30s background sleeps):
# armed reads {"tasks":1,"queued":0,"kinds":["local_bash"]} and returns to
# {"tasks":0,"queued":0,"kinds":[]} the moment the command completes.

FAKE_HOME="$TESTROOT/fakehome"
REAL_HOME="$HOME"

# Fabricate one daemon session: a state.json with the given state/tempo and
# raw inFlight JSON ("OMIT" writes no inFlight key at all), plus a two-line
# JSONL holding one tool_use and its matching tool_result, both back-dated
# <age> seconds so the stall grace window has (or hasn't) lapsed. Echoes the
# JSONL path. No daemon, no session, no LLM.
mk_session() {  # <id> <state> <tempo> <inflight-json|OMIT> <age-seconds>
  local id="$1" state="$2" tempo="$3" inflight="$4" age="$5"
  local dir="$FAKE_HOME/.claude/jobs/$id" now use_ts res_ts
  local jsonl="$TESTROOT/$id.jsonl"
  mkdir -p "$dir"
  if [[ "$inflight" == "OMIT" ]]; then
    printf '{"state":"%s","tempo":"%s"}\n' "$state" "$tempo" > "$dir/state.json"
  else
    printf '{"state":"%s","tempo":"%s","inFlight":%s}\n' \
      "$state" "$tempo" "$inflight" > "$dir/state.json"
  fi
  now=$(date +%s)
  use_ts=$(date -u -d "@$(( now - age - 1 ))" +%Y-%m-%dT%H:%M:%S.000Z)
  res_ts=$(date -u -d "@$(( now - age ))" +%Y-%m-%dT%H:%M:%S.000Z)
  {
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"toolu_%s","name":"Bash"}]}}\n' \
      "$use_ts" "$id"
    printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_%s","content":"Command running in background with ID: bx1"}]}}\n' \
      "$res_ts" "$id"
  } > "$jsonl"
  printf '%s' "$jsonl"
}

# "stall" if check_stall_signature would hand the worker to runner takeover.
# The optional <bg-max> overrides STALL_BG_MAX_S for this call only — verified
# in bash a prefix assignment on a FUNCTION does not outlive the call, so one
# case's override cannot leak into the next. Omitted, it re-supplies the value
# the runner itself set, so the unqualified cases exercise the shipped default.
stall_verdict() {  # <id> <inflight-json|OMIT> [state] [tempo] [age] [bg-max]
  local id="$1" jsonl
  jsonl=$(mk_session "$id" "${3:-working}" "${4:-idle}" "$2" "${5:-300}")
  HOME="$FAKE_HOME" INFLIGHT_UNAVAILABLE_LOGGED=1 STALL_BG_MAX_S="${6:-$STALL_BG_MAX_S}" \
    check_stall_signature "$id" "$jsonl" 2>/dev/null \
    && echo stall || echo not-a-stall
}

ARMED='{"tasks":1,"queued":0,"kinds":["local_bash"]}'
IDLE_BG='{"tasks":0,"queued":0,"kinds":[]}'

check "a worker awaiting backgrounded work is NOT a stall while quiet is under STALL_BG_MAX_S" \
  "not-a-stall" "$(stall_verdict armed "$ARMED")"
check "a quiet worker with no background work armed IS a stall (behavior preserved)" \
  "stall" "$(stall_verdict unarmed "$IDLE_BG")"
check "a quiet worker still inside the grace window is not yet a stall" \
  "not-a-stall" "$(stall_verdict fresh "$IDLE_BG" working idle 5)"
check "a mid-tool worker (tempo=active) is never a stall" \
  "not-a-stall" "$(stall_verdict busy "$IDLE_BG" working active)"

# Fail-safe: the count is an undocumented daemon internal. If it is absent,
# null, or non-numeric, the guard must degrade to "never take over" — NOT to
# the pre-fix behavior of killing healthy workers.
check "an absent inFlight field fails safe (not a stall)" \
  "not-a-stall" "$(stall_verdict absent OMIT)"
check "a null inFlight — the shape a stopped session writes — fails safe" \
  "not-a-stall" "$(stall_verdict nulled null)"
check "a non-numeric inFlight.tasks fails safe" \
  "not-a-stall" "$(stall_verdict garbage '{"tasks":"many"}')"
check "an inFlight object without a tasks key fails safe" \
  "not-a-stall" "$(stall_verdict notasks '{"queued":0,"kinds":[]}')"

# A leaked counter (observed: a 2.1.217 worker reached state=done still
# reporting tasks:28) is held the same way as any other armed count — under
# the default bound, which this fixture's 300s of quiet is nowhere near. The
# hold is bounded, not permanent (see the bound section below); the separate
# blocked-branch hold in wait_for_bg_session caps itself at BG_HOLD_MAX_S.
check "a leaked (never-decremented) count fails safe rather than killing" \
  "not-a-stall" "$(stall_verdict leaked '{"tasks":28,"queued":0,"kinds":["local_bash"]}')"

# ---- ...and the bound on that suppression ----------------------------
# The suppression is not unconditional, because a positive count is not always
# a transient condition. `inFlight` counts more than backgrounded Bash: a
# PERSISTENT Monitor stays armed for the worker's whole session — observed
# 2026-07-31 on 2.1.220, a session sitting at state=working tempo=idle with
# tasks=1 kinds=["monitor"] while its quiet climbed past 280s — and the daemon
# does not move a hung session to a terminal state. There, check_stall_signature
# is the ONLY recovery path (wait_for_bg_session's blocked branch, and
# BG_HOLD_MAX_S with it, is never reached) and TASK_QUEUE_TIMEOUT is empty by
# default, so an unbounded suppression wedges the runner on that task forever.
#
# The knob is overridden rather than the fixture back-dated half an hour, and
# the two cases below differ ONLY in the knob: 200s crosses the standing
# age-300 fixture, 400s does not. That pairing is what shows the bound is
# doing the work rather than some other gate flipping.
check "armed work quiet PAST the bound IS a stall — the runner is not wedged forever" \
  "stall" "$(stall_verdict bounded "$ARMED" working idle 300 200)"
check "the same fixture stays not-a-stall while the bound is above its quiet" \
  "not-a-stall" "$(stall_verdict unbounded "$ARMED" working idle 300 400)"

# The observed persistent-Monitor shape must behave exactly like plain
# backgrounded Bash on both sides of the bound. The fix reads the COUNT and
# nothing else: `kinds` stays unread by both runners, so a worker cannot be
# treated differently for the kind of work it armed.
MONITOR='{"tasks":2,"queued":0,"kinds":["local_bash","monitor"]}'
check "a persistent-Monitor count is held below the bound, like any other" \
  "not-a-stall" "$(stall_verdict monheld "$MONITOR" working idle 300 400)"
check "a persistent-Monitor count past the bound is a stall, like any other" \
  "stall" "$(stall_verdict moncrossed "$MONITOR" working idle 300 200)"

# Fail-safe ordering survives the bound. A worker whose latest tool_use has no
# tool_result yet is mid-tool — not quiet at all — so its quiet is unmeasurable
# and it must stay not-a-stall however low the bound is. Reading unmeasurable
# as "past the bound" would kill workers mid-tool: the 2026-07-31 incident
# with extra steps.
mk_session pendingarmed working idle "$ARMED" 300 >/dev/null
PENDING_ARMED_JSONL="$TESTROOT/pendingarmed.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"toolu_pendingarmed","name":"Bash"}]}}\n' \
  "$(date -u -d '@'"$(( $(date +%s) - 900 ))" +%Y-%m-%dT%H:%M:%S.000Z)" > "$PENDING_ARMED_JSONL"
if HOME="$FAKE_HOME" INFLIGHT_UNAVAILABLE_LOGGED=1 STALL_BG_MAX_S=1 \
     check_stall_signature pendingarmed "$PENDING_ARMED_JSONL" 2>/dev/null; then
  PENDING_ARMED_VERDICT="stall"
else
  PENDING_ARMED_VERDICT="not-a-stall"
fi
check "an armed worker with an outstanding tool_result stays not-a-stall past the bound" \
  "not-a-stall" "$PENDING_ARMED_VERDICT"

# Crossing the bound must be DISTINGUISHABLE in the log from an ordinary
# stall, so an operator can tell a stuck counter from a stuck model. Run
# DIRECTLY in this shell with stderr to a file — the same subshell discipline
# the note_inflight_unavailable block below documents. The expected prefix is
# matched too: the body is byte-identical across both runners, so the tag has
# to arrive through $LOG_TAG rather than as a literal (which mirror identity
# alone would not catch, both copies being equally wrong).
BOUND_JSONL=$(mk_session crossed working idle "$ARMED" 300)
HOME="$FAKE_HOME"
STALL_BG_MAX_S=200 check_stall_signature crossed "$BOUND_JSONL" 2>"$TESTROOT/bound.err" >/dev/null
HOME="$REAL_HOME"
case "$(cat "$TESTROOT/bound.err")" in
  "[task-queue] "*"still armed — past STALL_BG_MAX_S"*) BOUND_LOG_VERDICT="explained" ;;
  "")                                                   BOUND_LOG_VERDICT="silent" ;;
  *)                                                    BOUND_LOG_VERDICT="$(cat "$TESTROOT/bound.err")" ;;
esac
check "crossing the bound says so on stderr rather than taking over silently" \
  "explained" "$BOUND_LOG_VERDICT"

# The degradation must be VISIBLE — and exactly once. Both halves of that
# are easy to lose to a subshell, so this runs check_stall_signature the way
# wait_for_bg_session does: called DIRECTLY in this shell, with stderr sent
# to a file. Wrapping it in `$( )` instead would fork, discarding the
# once-only flag the second assertion is here to pin — the test would then
# pass against an implementation that logs on all 12 polls per minute.
NOTE_JSONL=$(mk_session noted working idle OMIT 300)
INFLIGHT_UNAVAILABLE_LOGGED=0
HOME="$FAKE_HOME"
check_stall_signature noted "$NOTE_JSONL" 2>"$TESTROOT/note1.err" >/dev/null
check_stall_signature noted "$NOTE_JSONL" 2>"$TESTROOT/note2.err" >/dev/null
HOME="$REAL_HOME"
case "$(cat "$TESTROOT/note1.err")" in
  *"no numeric inFlight.tasks"*) NOTE_VERDICT="warned" ;;
  "")                            NOTE_VERDICT="silent" ;;
  *)                             NOTE_VERDICT="other" ;;
esac
check "an unavailable count warns on stderr the first time" "warned" "$NOTE_VERDICT"
check "the warning is not repeated on every poll" "" "$(cat "$TESTROOT/note2.err")"
check "the once-only flag survived in the runner's own shell" \
  "1" "$INFLIGHT_UNAVAILABLE_LOGGED"
INFLIGHT_UNAVAILABLE_LOGGED=1

# worker_bg_work_armed resolves the unavailable case the OTHER way: it gates
# a hold, and holding on absent data is how a runner hangs forever.
armed_verdict() {  # <id>
  if HOME="$FAKE_HOME" worker_bg_work_armed "$1" 2>/dev/null; then echo armed; else echo not-armed; fi
}
check "worker_bg_work_armed reports armed when the daemon says tasks>0" \
  "armed" "$(armed_verdict armed)"
check "worker_bg_work_armed reports not-armed at tasks=0" \
  "not-armed" "$(armed_verdict unarmed)"
check "worker_bg_work_armed treats an unavailable count as NOT armed (no unbounded hold)" \
  "not-armed" "$(armed_verdict absent)"

# ---- worker_quiet_seconds: the shared quiet measurement ---------------
echo
echo "worker_quiet_seconds — the measurement check_stall_signature and the probe share"

# Split out of check_stall_signature so probe-completion-detection.sh can
# assert a LIVE session crossed STALL_GRACE_S using the runner's own
# measurement rather than a re-derived copy. Its three "unmeasurable" cases
# are each a deliberate not-a-stall in the caller, so they are pinned here
# rather than left implicit in the stall verdicts above.

QS_JSONL=$(mk_session quiet working idle "$IDLE_BG" 300)
QS=$(worker_quiet_seconds "$QS_JSONL")
# A range, not an equality: the fixture is back-dated relative to a `date`
# call that ran a moment before this one, so an exact match would be a
# clock-race away from a spurious failure.
if [[ "$QS" =~ ^[0-9]+$ ]] && (( QS >= 300 && QS <= 305 )); then
  QS_VERDICT="~300s"
else
  QS_VERDICT="$QS"
fi
check "quiet is measured from the latest tool_result" "~300s" "$QS_VERDICT"

qs_verdict() {  # <jsonl-path>
  local q
  q=$(worker_quiet_seconds "$1") && echo "$q" || echo unmeasurable
}

check "a missing JSONL is unmeasurable, not zero" \
  "unmeasurable" "$(qs_verdict "$TESTROOT/no-such.jsonl")"
check "an empty path is unmeasurable, not zero" \
  "unmeasurable" "$(qs_verdict "")"

# A tool_use with no tool_result yet — a tool STILL EXECUTING. Reporting 0
# here would be wrong in the opposite direction from reporting a large
# number: the session is not quiet at all, so the only honest answer is
# "not measurable", which the caller reads as not-a-stall.
PENDING_JSONL="$TESTROOT/pending.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"toolu_pending","name":"Bash"}]}}\n' \
  "$(date -u -d '@'"$(( $(date +%s) - 900 ))" +%Y-%m-%dT%H:%M:%S.000Z)" > "$PENDING_JSONL"
check "an outstanding tool_result is unmeasurable (a running tool is not quiet)" \
  "unmeasurable" "$(qs_verdict "$PENDING_JSONL")"

# No tool_use at all — too early in the dispatch to judge anything.
EARLY_JSONL="$TESTROOT/early.jsonl"
printf '{"type":"assistant","timestamp":"2026-07-31T00:00:00.000Z","message":{"content":[{"type":"text","text":"hi"}]}}\n' \
  > "$EARLY_JSONL"
check "a session with no tool_use yet is unmeasurable" \
  "unmeasurable" "$(qs_verdict "$EARLY_JSONL")"

HOME="$REAL_HOME"

# ---- bg_episode_track / bg_episode_close: the episode record ----------
echo
echo "bg_episode_track / bg_episode_close — the background-work episode record"

# The gate added after the 2026-07-31 incident is SILENT by construction: a
# suppressed false positive produces no output, so a runner log carries no
# evidence the guard ever engaged — or ever could have. The first end-to-end
# run after the fix passed cleanly while never once reaching the guarded
# state (255 of 258 sampled polls sat at tempo=active, where the older tempo
# gate already returns not-a-stall). Only a bespoke sampler running alongside
# caught that. These two log lines are what make the same miss visible in an
# ordinary runner log, and BG_EPISODE_IDLE_POLLS is the number that shows it.
#
# The bookkeeping lives in globals precisely so it can be driven HERE, with a
# scripted sequence of (armed, tempo) polls and a supplied clock — a 5s
# polling loop against a live daemon is otherwise untestable.

# Drive the bookkeeping through one scripted wait: each argument is one poll,
# written "<armed>:<tempo>", ticking a fake clock 5s per poll. Ends the wait
# the way wait_for_bg_session's terminal branches do. Echoes every line the
# bookkeeping emitted, and nothing else.
episode_trace() {  # <armed>:<tempo> ...
  local t=1000 spec armed tempo
  bg_episode_reset
  for spec in "$@"; do
    armed="${spec%%:*}"
    tempo="${spec##*:}"
    bg_episode_track ep0 "$armed" "$tempo" "$t" "$armed"
    t=$(( t + 5 ))
  done
  bg_episode_close ep0 "$t" "the wait ended"
}

# The single most important assertion in this block: a run that never enters
# the guarded state must say NOTHING. A record that appears either way would
# be exactly as uninformative as the silence it replaces.
check "a wait that never sees background work emits no record at all" \
  "" "$(episode_trace 0:idle 0:active 0:idle 0:blocked)"

# One episode, opened ONCE. A per-poll line would be 12 lines a minute of
# noise that reads as a storm of new events rather than one ongoing hold.
OPENS=$(episode_trace 1:idle 1:idle 1:idle 1:idle 1:idle 0:idle | grep -c 'background work in flight')
check "the open line is emitted once per episode, not once per poll" "1" "$OPENS"

CLOSES=$(episode_trace 1:idle 1:idle 1:idle 1:idle 1:idle 0:idle | grep -c 'episode ended')
check "the close line is emitted once per episode" "1" "$CLOSES"

# Elapsed, poll count, and the idle count — the three numbers the record
# exists to carry. Four armed polls at t=1000,1005,1010,1015 (three of them
# at tempo=idle), draining at t=1020.
TRACE=$(episode_trace 1:idle 1:idle 1:active 1:idle 0:idle)
case "$TRACE" in
  *"after 20s — 4 polls, 3 at tempo=idle"*) COUNT_VERDICT="20s/4/3" ;;
  *)                                        COUNT_VERDICT="$TRACE" ;;
esac
check "the close line carries elapsed, poll count, and idle-poll count" \
  "20s/4/3" "$COUNT_VERDICT"

# tempo=active polls are protected by the PRE-EXISTING tempo gate, so an
# episode spent entirely at tempo=active proves nothing about the inFlight
# gate. Zero decisive polls is the signature of the 2026-07-31 miss, and it
# has to be distinguishable in the log from a genuinely decisive hold.
ACTIVE_ONLY=$(episode_trace 1:active 1:active 1:active 0:active)
case "$ACTIVE_ONLY" in
  *"3 polls, 0 at tempo=idle"*) ACTIVE_VERDICT="0 decisive" ;;
  *)                            ACTIVE_VERDICT="$ACTIVE_ONLY" ;;
esac
check "an all-tempo=active episode records 0 idle polls (the 2026-07-31 miss shape)" \
  "0 decisive" "$ACTIVE_VERDICT"

check "a drained episode says so" "drained" \
  "$(episode_trace 1:idle 0:idle | grep -o "the daemon's count drained to 0" >/dev/null && echo drained || echo other)"

# A LEAKED counter — observed on Claude Code 2.1.217, a session reaching
# state=done still reporting tasks:28 — never drains. It must surface as an
# episode that closes on the runner's terms, with the qualifier saying so,
# rather than as an episode that silently never closes.
LEAK_TRACE=$(episode_trace 1:idle 1:idle 1:idle)
case "$LEAK_TRACE" in
  *"the wait ended"*) LEAK_VERDICT="closed-by-runner" ;;
  *)                  LEAK_VERDICT="$LEAK_TRACE" ;;
esac
check "an episode still armed when the wait ends is closed and labelled, not dropped" \
  "closed-by-runner" "$LEAK_VERDICT"

# Two separate stretches are two episodes, not one long one — otherwise the
# elapsed number would silently span a gap in which nothing was held.
TWO=$(episode_trace 1:idle 0:idle 1:idle 0:idle | grep -c 'background work in flight')
check "a second stretch of background work opens a second episode" "2" "$TWO"

# The log tag reaches the line through $LOG_TAG — the helper bodies are
# byte-identical across both runners, so a literal prefix would print
# "task-queue" out of the audit-queue runner.
case "$(episode_trace 1:idle 0:idle)" in
  "[task-queue] "*) TAG_VERDICT="tagged" ;;
  *)                TAG_VERDICT="$(episode_trace 1:idle 0:idle | head -1)" ;;
esac
check "records are prefixed from \$LOG_TAG, not a hardcoded runner name" \
  "tagged" "$TAG_VERDICT"

# bg_episode_reset must be the SILENT one. wait_for_bg_session calls it at
# the top of every wait; if it spoke, each new worker would inherit and
# report the previous worker's half-open episode as its own.
#
# Run DIRECTLY in this shell with stdout redirected to a file, never through
# `$( )` — the same subshell trap the note_inflight_unavailable block above
# documents. A forked call would leave the globals untouched here, so the
# state assertions would pass against an implementation that resets nothing.
bg_episode_reset
bg_episode_track ep1 1 idle 2000 1 >/dev/null
bg_episode_reset > "$TESTROOT/reset.out"
check "bg_episode_reset drops an open episode silently" "" "$(cat "$TESTROOT/reset.out")"
check "bg_episode_reset actually cleared the episode" "0" "$BG_EPISODE_SINCE"
# ...and a close after a reset has nothing left to say.
bg_episode_close ep1 2100 'the wait ended' > "$TESTROOT/close.out"
check "closing with no episode open is a no-op" "" "$(cat "$TESTROOT/close.out")"

# ---- worktree_busy: the teardown guard --------------------------------
echo
echo "worktree_busy — refuse to mutate a worktree that is mid-write"

BWT="$TESTROOT/busy-wt"
mkdir -p "$BWT"
git -C "$BWT" init -q -b main
printf 'tracked\n' > "$BWT/tracked.txt"
git -C "$BWT" add -A && git -C "$BWT" commit -qm "seed"

busy_verdict() { if worktree_busy "$1"; then echo "busy: $WORKTREE_BUSY_REASON"; else echo free; fi; }

check "a clean worktree is free to mutate" "free" "$(busy_verdict "$BWT")"

# The regression that makes the naive guard unusable: the runner itself
# symlinks untracked paths into every worktree (stage_shared_paths) and test
# runs leave more, so a plain `git status --porcelain` would report every
# healthy worktree as busy and stall the queue permanently.
printf 'artifact\n' > "$BWT/untracked-artifact.txt"
mkdir -p "$BWT/.venv" && printf 'x\n' > "$BWT/.venv/marker"
check "untracked build/test artifacts do NOT make a worktree busy" \
  "free" "$(busy_verdict "$BWT")"

printf 'edited\n' >> "$BWT/tracked.txt"
check "an uncommitted tracked edit makes a worktree busy" \
  "busy: uncommitted changes to tracked files" "$(busy_verdict "$BWT")"

# Staged-but-uncommitted is what a `git commit` looks like from the outside
# while its pre-commit gate runs — the exact window the 2026-07-31 teardown
# raced into.
git -C "$BWT" add tracked.txt
check "a staged-but-uncommitted change (a commit in flight) makes it busy" \
  "busy: uncommitted changes to tracked files" "$(busy_verdict "$BWT")"
git -C "$BWT" commit -qm "settle"
check "committing the change frees the worktree again" "free" "$(busy_verdict "$BWT")"

BWT_GITDIR="$(git -C "$BWT" rev-parse --absolute-git-dir)"
: > "$BWT_GITDIR/index.lock"
check "an index.lock (a git command running right now) makes it busy" \
  "busy: git operation in progress (index.lock present)" "$(busy_verdict "$BWT")"
rm -f "$BWT_GITDIR/index.lock"

: > "$BWT_GITDIR/MERGE_HEAD"
check "an in-progress merge makes it busy" \
  "busy: git operation in progress (MERGE_HEAD present)" "$(busy_verdict "$BWT")"
rm -f "$BWT_GITDIR/MERGE_HEAD"

check "a worktree that does not exist reads as busy, not free" \
  "busy: worktree directory is missing" "$(busy_verdict "$TESTROOT/no-such-worktree")"

# ---- mark_queue_file: marker commits + inbound-link repair ------------
echo
echo "mark_queue_file — marker commits repair inbound links (scratch git repos)"

# The 2026-08-01 wedge: a whole-tree doc-links gate refuses any commit
# that leaves markdown links pointing at a moved file, and every
# mark_queue_file marker commit moves the brief off its original path.
# The fix (_stage_link_repairs) mechanically rewrites the inbound links
# to the marker path and stages them into the same commit — guarded on
# the REPO-LOCAL scripts/repair_doc_links.py existing, so a repo
# without it (OMG has no doc-links gate) keeps the old behavior. That
# guard is why the repair cases below SKIP rather than fail where the
# script is absent, while the no-script case runs everywhere.
#
# These drive the REAL mark_queue_file. _halt_on_mark_failure exits the
# process, so every call runs in a subshell; a nonzero subshell exit
# plus a STUCK record in STATE_DIR is the halt signal.

REPAIR_SRC="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)/scripts/repair_doc_links.py"

mk_mark_repo() {  # <dir> <with-repair: yes|no>
  local r="$1" rel
  mkdir -p "$r/$QREL" "$r/docs/goals"
  git -C "$r" init -q -b main
  printf '# Brief\n' > "$r/$QREL/mq-task.md"
  # A goal doc linking to the brief — the inbound link that wedged the
  # 2026-08-01 marker commits.
  rel="$(realpath --relative-to="$r/docs/goals" "$r/$QREL/mq-task.md")"
  printf -- '- [MQ task](%s) pending\n' "$rel" > "$r/docs/goals/list.md"
  if [[ "$2" == "yes" ]]; then
    mkdir -p "$r/scripts"
    cp "$REPAIR_SRC" "$(dirname "$REPAIR_SRC")/check_doc_links.py" "$r/scripts/"
  fi
  git -C "$r" add -A && git -C "$r" commit -qm seed
}

OLD_ROOT="$ROOT"; OLD_STATE_DIR="$STATE_DIR"
STATE_DIR="$TESTROOT/mark-state"; mkdir -p "$STATE_DIR"

if [[ ! -f "$REPAIR_SRC" ]]; then
  skip "marker commits repair inbound links (3 cases)" \
       "no scripts/repair_doc_links.py in this repo — repair is repo-local"
else
  # Plain (rename) marker: the linking doc is rewritten to the marker
  # path and committed atomically with the rename.
  MQR="$TESTROOT/mark-rename"
  mk_mark_repo "$MQR" yes
  ROOT="$MQR"
  ( mark_queue_file "$MQR/$QREL/mq-task.md" crashed 20260803-010101 ) >/dev/null 2>&1
  check "a plain marker commit lands despite an inbound link" "0" "$?"
  check "the inbound link now points at the marker path" \
    "- [MQ task]($(realpath --relative-to="$MQR/docs/goals" "$MQR/$QREL")/mq-task.crashed.20260803-010101.md) pending" \
    "$(cat "$MQR/docs/goals/list.md")"
  # Cleanliness here means TRACKED files match HEAD — the runner's own
  # DIRTY definition. The repair's python import drops an untracked
  # scripts/__pycache__/, which no runner path counts as dirt.
  check "the link repair is committed WITH the rename, leaving main clean" \
    "clean" "$( git -C "$MQR" diff --quiet HEAD && echo clean || git -C "$MQR" status --porcelain )"
  check "one marker commit advanced HEAD" "2" "$(git -C "$MQR" rev-list --count HEAD)"

  # Merge-failed marker: rm+stub instead of rename, same repair — the
  # link ends up resolving to the dissimilar stub.
  MQF="$TESTROOT/mark-merge-failed"
  mk_mark_repo "$MQF" yes
  ROOT="$MQF"
  ( mark_queue_file "$MQF/$QREL/mq-task.md" merge-failed 20260803-020202 ) >/dev/null 2>&1
  check "a merge-failed marker commit lands despite an inbound link" "0" "$?"
  check "the inbound link resolves to the merge-failed stub" \
    "stub" "$( grep -q 'mq-task.merge-failed.20260803-020202.md' "$MQF/docs/goals/list.md" \
               && [[ -f "$MQF/$QREL/mq-task.merge-failed.20260803-020202.md" ]] && echo stub || echo broken )"
  check "the merge-failed repo is left clean" \
    "clean" "$( git -C "$MQF" diff --quiet HEAD && echo clean || echo dirty )"

  # A broken repair script must halt loudly and roll the staging back —
  # the fail-stop discipline every other staging failure follows.
  MQB="$TESTROOT/mark-broken"
  mk_mark_repo "$MQB" yes
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$MQB/scripts/repair_doc_links.py"
  ROOT="$MQB"
  ( mark_queue_file "$MQB/$QREL/mq-task.md" crashed 20260803-030303 ) >/dev/null 2>&1
  MQB_EXIT="$?"
  check "a failing repair script halts the runner instead of committing" \
    "halted" "$( [[ "$MQB_EXIT" -ne 0 ]] && echo halted || echo continued )"
  check "the halt left a STUCK record naming the failure" \
    "recorded" "$( grep -ql 'inbound-link repair failed' "$STATE_DIR"/STUCK-*-mark-failed-mq-task.md 2>/dev/null && echo recorded || echo missing )"
  check "the staged rename was rolled back (brief intact, nothing staged, HEAD unmoved)" \
    "rolled-back" "$( [[ -f "$MQB/$QREL/mq-task.md" ]] \
                      && git -C "$MQB" diff --cached --quiet \
                      && [[ "$(git -C "$MQB" rev-list --count HEAD)" == "1" ]] \
                      && echo rolled-back || echo residue )"
fi

# No repair script at all — the OMG shape. The guard must make this a
# clean no-op: the marker commit lands exactly as before the fix, the
# inbound link left alone.
MQN="$TESTROOT/mark-no-script"
mk_mark_repo "$MQN" no
ROOT="$MQN"
( mark_queue_file "$MQN/$QREL/mq-task.md" crashed 20260803-040404 ) >/dev/null 2>&1
check "without the repo-local repair script the marker commit still lands" "0" "$?"
check "without the script the inbound link is left untouched" \
  "untouched" "$( grep -q 'mq-task.md) pending' "$MQN/docs/goals/list.md" && echo untouched || echo rewritten )"
check "without the script the repo is still left clean" \
  "clean" "$( git -C "$MQN" diff --quiet HEAD && echo clean || echo dirty )"

ROOT="$OLD_ROOT"; STATE_DIR="$OLD_STATE_DIR"

# ---- mirror identity: task-queue vs audit-queue -----------------------
echo
echo "mirror identity — shared helpers are byte-identical in both runners"

# The two runners carry these functions verbatim. Divergence is the failure
# mode this converts from a "keep these in sync" comment into a check: the
# 2026-07-31 stall race existed identically in both, and a fix applied to
# one only would leave the other exposed with no signal.
AUDIT_RUN_SH="$SKILL_DIR/../audit-queue/run.sh"
if [[ ! -f "$AUDIT_RUN_SH" ]]; then
  skip "shared helpers are identical in both runners (11 functions)" \
       "no audit-queue sibling in this repo — nothing to mirror against"
else
  for fn in worker_bg_task_count note_inflight_unavailable worker_bg_work_armed \
            worker_quiet_seconds bg_episode_track bg_episode_reset \
            bg_episode_close check_stall_signature worker_awaiting_user \
            worker_in_clarification_dialog worktree_busy; do
    TQ_BODY="$(sed -n "/^$fn() {/,/^}/p" "$SKILL_DIR/run.sh")"
    AQ_BODY="$(sed -n "/^$fn() {/,/^}/p" "$AUDIT_RUN_SH")"
    if [[ -z "$TQ_BODY" ]]; then
      MIRROR_VERDICT="missing from task-queue/run.sh"
    elif [[ -z "$AQ_BODY" ]]; then
      MIRROR_VERDICT="missing from audit-queue/run.sh"
    elif [[ "$TQ_BODY" == "$AQ_BODY" ]]; then
      MIRROR_VERDICT="identical"
    else
      MIRROR_VERDICT="DIVERGED:"$'\n'"$(diff <(printf '%s\n' "$TQ_BODY") <(printf '%s\n' "$AQ_BODY"))"
    fi
    check "$fn is identical in both runners" "identical" "$MIRROR_VERDICT"
  done
fi

# ---- source-guard: loading a runner must have no side effects ---------
echo
echo "source guard — both runners load without parsing args, stopping, or launching"

# The mirror assertion above compares function *bodies* with `sed` and never
# sources the sibling. That is the gap this closes. Both probe scripts and
# this suite load a runner to borrow its real functions, and a sourced script
# sees the CALLER's positional parameters — so whatever `$1` the loader was
# invoked with is what the runner's argument parsing reads.
#
# Before the guard landed, audit-queue/run.sh had no source-guard at all: it
# only avoided launching because it rejected the probes' `$1` (`audit-queue`)
# as an invalid audit type and `exit 1`ed the sourcing script with it. That is
# a rejection, not a guard, and it fails in both directions — it broke
# `probe-*.sh audit-queue` outright, and a `$1` that IS a valid audit type
# would have fallen through to the detach block and started a real runner.
#
# So the hostile values below are chosen for what each one reaches:
#   code-quality — a VALID audit type: the case that would start a runner.
#   stop         — needs no valid type; would touch the stop sentinel and
#                  gracefully stop every runner on the host.
#   recover      — needs no valid type; would run reconcile_orphans.
#
# Each source runs in a fresh `bash -c` rather than a subshell of this file:
# a subshell inherits the functions this file already sourced at the top (see
# "load the runner's functions"), which would make "is the helper defined
# afterward?" vacuously true for task-queue. The
# explicit `$0` is this file's path — both runners resolve ROOT via
# `git -C "$(dirname "$0")" rev-parse --show-toplevel`, and `bash -c` would
# otherwise leave `$0` as a bare `bash`.
#
# `set -euo pipefail` inside is deliberate and load-bearing: it is what the
# probes run under, and it means a source that merely *returns non-zero* —
# e.g. from a trailing `[[ … ]] && FLAG=1` that evaluated false — fails here
# rather than passing quietly.
#
# WARNING to anyone running the negative control (reverting a guard and
# re-running this section to confirm it fails): against an unguarded runner
# these cases really do what they are testing for. The 2026-07-31 control
# touched the stop sentinel and left three detached runners behind — rooted
# at this worktree, and detached under `task-queue/run.sh` because `SELF`
# resolves through `$0`. Check `pgrep`, `<root>/.{audit,task}-queue/`, and
# `git worktree list` afterwards; do not run it on a tree where a real runner
# is working.
source_probe() {  # <runner.sh> <helper-fn> <hostile-$1>  -> "returned:<type>" or ""
  bash -c '
    set -euo pipefail
    runner="$1"; fn="$2"; shift 2
    # shellcheck source=/dev/null
    source "$runner"
    # Reached only if the source RETURNED. An `exit` anywhere in the runner
    # kills this shell first, and the empty output is the failure signal.
    printf "returned:%s\n" "$(type -t "$fn" 2>/dev/null || echo undefined)"
  ' "$SKILL_DIR/test-run.sh" "$@" 2>/dev/null
}

# All three verdicts come from ONE source, snapshotted either side of it.
#
# Splitting them into three calls looked tidier and was wrong: the first call
# already did the damage, so the sentinel was present *before* the second call
# and the runner already running *before* the third — both reported "no
# change" against a runner that had demonstrably just stopped every runner on
# the host and launched another. Verified 2026-07-31 as a negative control:
# with the guard reverted, the split form passed 2 of every 3 assertions it
# exists to fail. A check whose pass state is reachable by the failure it
# looks for is decorative; see docs/signal-hygiene.md.
#
# Neither snapshot asks "does it exist?" — that would fail spuriously against
# a real runner mid-stop on the same tree. Both ask "did this source CHANGE
# it?": the sentinel by identity+mtime (`stop` re-touches an existing file),
# and the launch by counting the runner logs the detach block writes before
# it forks. The log count is the reliable launch signal precisely because the
# detached process's own command line is not: a sourced runner resolves
# `SELF` through `$0`, so it re-execs under the *caller's* path — the reverted
# run above detached as `bash …/task-queue/run.sh`, which a pgrep for the
# audit-queue path never matches.
SG_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
sg_stamp()  { stat -c '%i:%Y' "$1" 2>/dev/null || echo absent; }
sg_logs()   { local n; n=$(ls -1 "$1"/runner-*.out 2>/dev/null | wc -l); echo "$n"; }

sg_verdict() {  # <runner.sh> <helper> <state-dir> <hostile-$1>
  local runner="$1" fn="$2" statedir="$3" arg="$4"
  local sent_before sent_after logs_before logs_after out load sentinel launch
  sent_before="$(sg_stamp "$statedir/stop")"
  logs_before="$(sg_logs "$statedir")"
  out="$(source_probe "$runner" "$fn" "$arg")"
  sleep 1   # a detach would have forked by now; `script` allocates a pty first
  sent_after="$(sg_stamp "$statedir/stop")"
  logs_after="$(sg_logs "$statedir")"

  # Empty output means the source never reached the printf — it exited.
  if [[ -n "$out" ]]; then load="$out"; else load="exited"; fi
  if [[ "$sent_before" == "$sent_after" ]]; then sentinel=untouched; else sentinel=TOUCHED; fi
  if (( logs_after > logs_before )); then launch=LAUNCHED; else launch=none; fi
  echo "load=$load sentinel=$sentinel runner=$launch"
}

for spec in \
  "audit-queue:pick_next_audit_path:$SG_ROOT/.audit-queue" \
  "task-queue:claim_next_task:$SG_ROOT/.task-queue"; do
  IFS=: read -r SG_NAME SG_FN SG_STATE <<< "$spec"
  SG_SH="$SKILL_DIR/../$SG_NAME/run.sh"
  if [[ ! -f "$SG_SH" ]]; then
    skip "$SG_NAME source guard (3 hostile \$1 values)" \
         "no $SG_NAME sibling in this repo"
    continue
  fi
  # `code-quality` is a VALID audit type — the case that reaches the detach
  # block. `stop` and `recover` need no valid type and are worse: they act
  # before the parser runs.
  for SG_ARG in code-quality stop recover; do
    check "$SG_NAME sourced with \$1=$SG_ARG: returns, defines helpers, changes nothing" \
      "load=returned:function sentinel=untouched runner=none" \
      "$(sg_verdict "$SG_SH" "$SG_FN" "$SG_STATE" "$SG_ARG")"
  done
done

# The shape the probes actually use, and the one that never worked before the
# guard: `probe-completion-detection.sh audit-queue` sources the runner with
# `audit-queue` — not a valid audit type — sitting in $1.
if [[ -f "$SKILL_DIR/../audit-queue/run.sh" ]]; then
  check "audit-queue sourced with the probes' own \$1 returns instead of rejecting it" \
    "load=returned:function sentinel=untouched runner=none" \
    "$(sg_verdict "$SKILL_DIR/../audit-queue/run.sh" pick_next_audit_path \
         "$SG_ROOT/.audit-queue" audit-queue)"
else
  skip "audit-queue sourced with the probes' own \$1 returns instead of rejecting it" \
       "no audit-queue sibling in this repo"
fi

# ---- summary ---------------------------------------------------------
echo
if (( SKIP > 0 )); then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
  echo "  ($SKIP assertion group(s) skipped — see SKIP lines above for what went unchecked)"
else
  echo "$PASS passed, $FAIL failed"
fi
[[ $FAIL -eq 0 ]]
