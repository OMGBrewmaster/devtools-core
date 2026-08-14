#!/usr/bin/env bash
# probe-completion-detection.sh — prove the background-work guard, live.
#
# Drives a REAL `claude --bg` session into the exact state the guard exists to
# protect — idle, quiet well past STALL_GRACE_S, with backgrounded work still
# armed — and asserts that the runner's OWN check_stall_signature declines to
# call it a stall throughout. Then asserts the complement: once the work
# drains and the session is quiet past grace, a stall IS declared.
#
# Why this exists
# ---------------
# The guard added on 2026-07-31 (063f49cd2) is well covered by unit tests over
# fabricated state.json / JSONL fixtures, but those fixtures are our own
# transcription of the daemon's shape. Only a live session proves the daemon
# still writes what we think it writes.
#
# The obvious live check — "queue a task and watch it pass" — does NOT work.
# The first real end-to-end run after the fix (2026-07-31, merged at
# 8ba9aa2c0) passed cleanly and proved nothing: a sampler running alongside
# recorded 255 of 258 polls at tempo=active, and check_stall_signature's FIRST
# gate is `[[ "$tempo" != "idle" ]] && return 1`, which predates the fix. The
# new inFlight check was never reached. Whether a given worker reaches the
# guarded state depends on how it chooses to await its backgrounded commands —
# a polling loop keeps the turn alive at tempo=active; ending the turn to await
# the completion notification drops it to tempo=idle. Both styles are
# legitimate, both occur, and nothing specifies which. So "queue another task
# and watch" is a coin flip we do not control.
#
# This probe removes the coin flip by INSTRUCTING its session to end its turn,
# and — critically — by failing when the guarded state is not reached. A run
# that never enters the window has verified nothing and must not report
# success; that substitution is what left the gap this script closes.
#
# Usage
# -----
#   bash probe-completion-detection.sh [task-queue|audit-queue|/path/to/run.sh]
#
# The runner argument selects which run.sh to source and exercise; it defaults
# to task-queue. Probing one runner does NOT validate the other beyond the
# shared helpers — see this skill's README.
#
# A path (any argument containing a "/") is accepted so the guard can be
# probed against a DELIBERATELY BROKEN copy of a runner. That negative control
# is the only way to know this script can fail; see "Negative control" in the
# README.
#
# Costs a few cents on a cheap model and runs in about four minutes. Needs no
# queued task, no merge to main, and no worker on the default model. It stops
# the session it spawns, including on Ctrl-C or an assertion failure.
#
# Exit codes: 0 = guard proven, 1 = assertion failed, 2 = could not set up.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHYSICAL_SKILL_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
MOUNT_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

# Prefer a sibling in the physical devtools tree, then a repo-local sibling
# exposed beside the mounting repo's logical skill surface. This preserves
# native and vendored whole-tree layouts while supporting PIA Maker's audit
# runner. See docs/skill-path-resolution.md.
resolve_runner() {  # <task-queue|audit-queue> -> path, or exits non-zero
  local name="$1" candidate
  case "$name" in
    task-queue) candidate="$SKILL_DIR/run.sh" ;;
    audit-queue)
      candidate="$PHYSICAL_SKILL_DIR/../audit-queue/run.sh"
      [[ -f "$candidate" ]] || candidate="$MOUNT_ROOT/.agents/skills/audit-queue/run.sh"
      ;;
    *) return 1 ;;
  esac
  [[ -f "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

# ---- resolve the runner under test -----------------------------------
RUNNER_ARG="${1:-task-queue}"
case "$RUNNER_ARG" in
  */*)                    RUNNER_SH="$RUNNER_ARG"; RUNNER_NAME="$RUNNER_ARG" ;;
  task-queue|audit-queue)
    if ! RUNNER_SH="$(resolve_runner "$RUNNER_ARG")"; then
      echo "probe: no such runner script: $RUNNER_ARG" >&2
      exit 2
    fi
    RUNNER_NAME="$RUNNER_ARG"
    ;;
  *)
    echo "probe: unknown runner '$RUNNER_ARG' (expected task-queue, audit-queue, or a path to a run.sh)" >&2
    exit 2
    ;;
esac
if [[ ! -f "$RUNNER_SH" ]]; then
  echo "probe: no such runner script: $RUNNER_SH" >&2
  exit 2
fi

# Resolver coverage can exercise every supported spelling without creating a
# real Claude session. This is deliberately an environment-only test seam,
# not an operator mode; normal invocations continue directly to the live
# prerequisites below.
if [[ "${TASK_QUEUE_PROBE_RESOLVE_ONLY:-0}" == "1" ]]; then
  echo "probe: resolved runner: $RUNNER_SH"
  exit 0
fi

for tool in claude jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "probe: $tool is not on PATH" >&2; exit 2; }
done

# Source the runner so the assertions below run its REAL functions rather
# than a copy. Its source-guard stops before the polling loop, so nothing is
# dispatched and no task is claimed — the same way test-run.sh loads it. Both
# runners answer `[[ "${BASH_SOURCE[0]}" != "${0}" ]]`, but in different
# shapes: task-queue defines every function first and needs one late
# `return 0`, while audit-queue parses arguments first and so computes a
# SOURCED flag up front and gates its `stop`/`recover`/parser blocks on it.
# That matters here — a sourced script sees the CALLER's positional
# parameters, so this probe's own `$1` (`audit-queue`) lands in the runner's
# `$1`. `task-queue/test-run.sh` asserts both runners load inertly.
# shellcheck source=/dev/null
source "$RUNNER_SH"
trap - INT TERM HUP   # belt-and-suspenders: the runner registers its signal
                      # traps only in the executed section, so nothing is set.

GRACE="${STALL_GRACE_S:-30}"
POLL_S="${PROBE_POLL_S:-5}"
PROBE_MODEL="${PROBE_MODEL:-sonnet}"
# The backgrounded command must outlast the grace window by enough polls that
# the window is unmistakably entered rather than brushed. At the defaults this
# yields ~12 in-window samples.
SLEEP_S="${PROBE_SLEEP_S:-90}"
# Ceilings. Phase 1 must outlast SLEEP_S plus dispatch; phase 2 needs only to
# outlast the grace window plus whatever the model says on being re-invoked.
PHASE1_MAX_S="${PROBE_PHASE1_MAX_S:-300}"
PHASE2_MAX_S="${PROBE_PHASE2_MAX_S:-240}"

SHORT_ID=""
cleanup() {
  if [[ -n "$SHORT_ID" ]]; then
    echo "probe: stopping session $SHORT_ID"
    claude stop "$SHORT_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "=================================================================="
echo "probe-completion-detection — runner: $RUNNER_NAME"
echo "  grace=${GRACE}s  poll=${POLL_S}s  bg-command=sleep ${SLEEP_S}  model=$PROBE_MODEL"
echo "=================================================================="

# ---- dispatch ---------------------------------------------------------
# Two instructions in this prompt are load-bearing, one per phase.
#
# END THE TURN (phase 1) is the whole point of the probe. A session that polls
# its own backgrounded command keeps the daemon at tempo=active, where the
# pre-existing tempo gate — not the inFlight gate — is what prevents takeover,
# and the probe would prove nothing. This is exactly how the 2026-07-31
# end-to-end run missed the window.
#
# REPLY WITH TEXT, THEN GO SILENT (phase 2) is what keeps the complement
# observable. The daemon flips tempo to active in the SAME poll in which it
# decrements the counter — measured 2026-07-31, a drain sample already read
# tempo=active — so there is no quiet-and-unarmed window at the drain instant
# to catch. The window that does exist is afterwards: a session that answers
# its completion notification with plain text and then stays quiet sits at
# state=working tempo=idle tasks=0 while quiet climbs (observed: 60s+ with no
# further nudge), which is precisely the unarmed stall shape. A session that
# instead ends with NO text is closed out by the daemon as state=done within
# about five seconds, and terminal states are excluded from stall detection by
# design — leaving the complement unobservable. So the text reply is required,
# not optional.
PROBE_PROMPT="Run exactly one command and nothing else.

Use the Bash tool with run_in_background set to true to run:

    sleep $SLEEP_S

You will get an immediate \"running in background\" result. Then STOP: end your
turn right away. Do not poll it, do not sleep, do not check on it, do not run
any other command, do not read or write any files, do not explain anything.

Later you will be re-invoked — by a completion notification for that command,
or by a \"Continue from where you left off\" nudge. EVERY time that happens,
do exactly this and nothing else:

  Reply with this single line of plain text:

      PROBE ACK

  Make NO tool call of any kind. Do not run commands. Do not investigate
  anything. Do not ask questions. Emit that one line and end your turn.

Emitting that line matters: a turn that ends with no text at all causes this
session to be closed out, and the probe needs it to stay open and quiet."

DISPATCH_OUT=$(mktemp)
claude --bg --name "probe-completion-detection" \
  --model "$PROBE_MODEL" \
  --permission-mode bypassPermissions \
  "$PROBE_PROMPT" > "$DISPATCH_OUT" 2>&1
DISPATCH_EXIT=$?
if (( DISPATCH_EXIT != 0 )); then
  echo "probe: claude --bg failed to dispatch (exit $DISPATCH_EXIT)" >&2
  cat "$DISPATCH_OUT" >&2
  rm -f "$DISPATCH_OUT"
  exit 2
fi
# Strip ANSI before parsing. `claude` colorizes the short id whenever
# FORCE_COLOR is set in the environment — which it is inside a Claude Code
# session — and the bare `[a-f0-9]+` match then silently captures nothing.
SHORT_ID=$(sed -e 's/\x1b\[[0-9;]*m//g' "$DISPATCH_OUT" \
            | grep -oE '^backgrounded · [a-f0-9]+' | head -1 | awk '{print $3}')
rm -f "$DISPATCH_OUT"
if [[ -z "$SHORT_ID" ]]; then
  echo "probe: could not parse a session id out of the claude --bg output" >&2
  exit 2
fi
echo "probe: dispatched session $SHORT_ID"

STATE_FILE="$HOME/.claude/jobs/$SHORT_ID/state.json"
for _ in $(seq 1 30); do
  [[ -f "$STATE_FILE" ]] && break
  sleep 1
done
if [[ ! -f "$STATE_FILE" ]]; then
  echo "probe: daemon never wrote $STATE_FILE" >&2
  exit 2
fi

JSONL=""
locate_jsonl() {
  if [[ -z "$JSONL" || ! -f "$JSONL" ]]; then
    JSONL=$(find "$HOME/.claude/projects" -maxdepth 2 -name "${SHORT_ID}*.jsonl" \
              ! -path '*/subagents/*' 2>/dev/null | head -1)
  fi
}

# One sample of the live session. Sets S_STATE / S_TEMPO / S_TASKS / S_QUIET /
# S_VERDICT. Every input except S_VERDICT is read straight from the daemon and
# the JSONL — deliberately NOT from check_stall_signature — so that removing
# the gate under test changes the VERDICT while leaving the window definition
# intact. A probe that defined its window in terms of the function it is
# testing would report "window never reached" for a broken guard instead of
# reporting a violation, and a skipped assertion reads far too much like a
# passing one.
sample() {
  locate_jsonl
  S_STATE=$(jq -r '.state // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
  S_TEMPO=$(jq -r '.tempo // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
  S_TASKS=$(worker_bg_task_count "$SHORT_ID") || S_TASKS="NA"
  S_QUIET=$(worker_quiet_seconds "$JSONL") || S_QUIET="NA"
  if check_stall_signature "$SHORT_ID" "$JSONL" 2>/dev/null; then
    S_VERDICT="stall"
  else
    S_VERDICT="not-a-stall"
  fi
}

# True when this sample is inside the guarded window: the session is idle and
# non-terminal, work is armed, and it has been quiet longer than the runner
# would tolerate from an unarmed worker. Absent the inFlight gate, every one
# of these is a takeover.
in_window() {
  [[ "$S_TEMPO" == "idle" ]] || return 1
  case "$S_STATE" in done|stopped|failed|blocked) return 1 ;; esac
  [[ "$S_TASKS" =~ ^[0-9]+$ ]] || return 1
  (( S_TASKS > 0 )) || return 1
  [[ "$S_QUIET" =~ ^[0-9]+$ ]] || return 1
  (( S_QUIET >= GRACE ))
}

show() {  # <phase>
  printf '  %-8s %-9s state=%-8s tempo=%-7s tasks=%-3s quiet=%-4s -> %s\n' \
    "$(date +%H:%M:%S)" "$1" "$S_STATE" "$S_TEMPO" "$S_TASKS" "$S_QUIET" "$S_VERDICT"
}

# ---- phase 1: armed, idle, quiet past grace --------------------------
echo
echo "--- phase 1: background work armed; the guard must decline to call it a stall"

ARMED_SAMPLES=0        # any sample with tasks > 0
WINDOW_SAMPLES=0       # ...that also reached the guarded window
WINDOW_VIOLATIONS=0    # ...where the guard nevertheless said "stall"
MAX_QUIET_ARMED=0
SAW_ARMED=0
P1_START=$(date +%s)

while (( $(date +%s) - P1_START < PHASE1_MAX_S )); do
  sample
  show "phase1"
  if [[ "$S_TASKS" =~ ^[0-9]+$ ]] && (( S_TASKS > 0 )); then
    SAW_ARMED=1
    ARMED_SAMPLES=$(( ARMED_SAMPLES + 1 ))
    if [[ "$S_QUIET" =~ ^[0-9]+$ ]] && (( S_QUIET > MAX_QUIET_ARMED )); then
      MAX_QUIET_ARMED=$S_QUIET
    fi
    if in_window; then
      WINDOW_SAMPLES=$(( WINDOW_SAMPLES + 1 ))
      if [[ "$S_VERDICT" == "stall" ]]; then
        WINDOW_VIOLATIONS=$(( WINDOW_VIOLATIONS + 1 ))
        echo "           ^^ VIOLATION: guarded state, yet the runner would take over"
      fi
    fi
  elif (( SAW_ARMED )); then
    # The count has gone back to 0 — phase 1 is over either way, and phase 2
    # takes it from here.
    break
  fi
  case "$S_STATE" in
    done|stopped|failed) break ;;
  esac
  sleep "$POLL_S"
done

# ---- phase 2: drained, idle, quiet past grace ------------------------
# Without this half the probe would pass just as happily against a runner
# whose stall detection had been deleted outright.
echo
echo "--- phase 2: background work drained; a stall must now BE declared"

COMPLEMENT_MET=0
P2_START=$(date +%s)
while (( $(date +%s) - P2_START < PHASE2_MAX_S )); do
  sample
  show "phase2"
  if [[ "$S_TEMPO" == "idle" ]] \
     && [[ "$S_TASKS" =~ ^[0-9]+$ ]] && (( S_TASKS == 0 )) \
     && [[ "$S_QUIET" =~ ^[0-9]+$ ]] && (( S_QUIET >= GRACE )) \
     && [[ "$S_VERDICT" == "stall" ]]; then
    case "$S_STATE" in
      done|stopped|failed|blocked) : ;;
      *) COMPLEMENT_MET=1; break ;;
    esac
  fi
  case "$S_STATE" in
    done|stopped|failed) break ;;
  esac
  sleep "$POLL_S"
done

# ---- verdict ---------------------------------------------------------
echo
echo "=================================================================="
echo "observed window"
echo "  samples with background work armed ......... $ARMED_SAMPLES"
echo "  ...that reached the guarded state .......... $WINDOW_SAMPLES"
echo "     (tempo=idle, non-terminal, tasks>0, quiet >= ${GRACE}s)"
echo "  longest quiet stretch while armed .......... ${MAX_QUIET_ARMED}s"
echo "  guard violations inside that state .......... $WINDOW_VIOLATIONS"
echo "  complement (unarmed + quiet => stall) ....... $( (( COMPLEMENT_MET )) && echo observed || echo NOT-observed)"
echo "=================================================================="

FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

# Reached-the-state comes first, and deliberately so. Every assertion below it
# is vacuously satisfiable by a session that never got there.
if (( WINDOW_SAMPLES > 0 )); then
  pass "the guarded state was genuinely reached ($WINDOW_SAMPLES samples, quiet up to ${MAX_QUIET_ARMED}s vs a ${GRACE}s grace)"
else
  fail "the guarded state was NEVER reached — this run proves nothing about the guard"
  if (( ARMED_SAMPLES == 0 )); then
    echo "      background work was never armed at all; did the session run its command?"
  else
    echo "      work was armed for $ARMED_SAMPLES samples but never at tempo=idle past ${GRACE}s"
    echo "      (a session that polls its own backgrounded command stays at tempo=active,"
    echo "       where the older tempo gate — not the inFlight gate — is what holds takeover off)"
  fi
fi

if (( WINDOW_SAMPLES > 0 && WINDOW_VIOLATIONS == 0 )); then
  pass "check_stall_signature declined to declare a stall throughout the guarded state"
elif (( WINDOW_VIOLATIONS > 0 )); then
  fail "check_stall_signature declared a stall in $WINDOW_VIOLATIONS of $WINDOW_SAMPLES guarded samples — the runner would have killed a healthy worker mid-command"
fi

if (( COMPLEMENT_MET )); then
  pass "with nothing armed and the session quiet past grace, a stall WAS declared"
else
  fail "the complement was never observed — stall detection may be disabled outright, or the session never settled into an unarmed quiet state"
fi

echo
if (( FAILED )); then
  echo "PROBE FAILED — the $RUNNER_NAME background-work guard is NOT proven by this run."
  exit 1
fi
echo "PROBE PASSED — the $RUNNER_NAME background-work guard held in the state it exists for."
exit 0
