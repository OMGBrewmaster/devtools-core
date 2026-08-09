#!/usr/bin/env bash
# probe-persistent-inflight.sh — prove the bound on the guard, live.
#
# Sibling of probe-completion-detection.sh, and the complement of it. That
# script proves the background-work guard HOLDS for a worker legitimately
# awaiting a backgrounded command. This one proves the guard eventually LETS
# GO of a worker whose count never drains — the hole the bound closes.
#
# Why this exists
# ---------------
# `inFlight` counts more than backgrounded Bash. A *persistent* Monitor stays
# armed for the worker's whole session, so `bg_tasks > 0` stops being a
# transient condition and becomes a property of the session. The daemon does
# not move a hung session to a terminal state either, so such a worker sits at
# state=working tempo=idle indefinitely — a state in which
# check_stall_signature is the ONLY recovery path the runner has:
# wait_for_bg_session's done/failed/stopped branches never fire, its
# state=blocked branch (and BG_HOLD_MAX_S with it) is never reached, and
# TASK_QUEUE_TIMEOUT / AUDIT_QUEUE_TIMEOUT are empty by default. Before
# STALL_BG_MAX_S the suppression was unbounded, so the runner waited forever
# and the queue stopped.
#
# Measured 2026-07-31 on Claude Code 2.1.220 with an unbounded runner: a
# session that armed one persistent Monitor and went quiet held
# `{"tasks":1,"kinds":["monitor"]}` at state=working tempo=idle across 281s of
# unbroken quiet — every sample a not-a-stall, with no sign of ever stopping.
#
# What this probe adds over the unit tests. test-run.sh drives the bound over
# FABRICATED state.json and JSONL fixtures — our own transcription of the
# daemon's shape. Only a live session shows that a real persistent Monitor
# still parks a real session in that state, and that the takeover the bound
# authorizes actually recovers it.
#
# Usage
# -----
#   bash probe-persistent-inflight.sh [task-queue|audit-queue|/path/to/run.sh]
#
# The runner argument selects which run.sh to source and exercise; it defaults
# to task-queue. A path (any argument containing a "/") is accepted so the
# bound can be probed against a DELIBERATELY BROKEN copy of a runner — the
# negative control that shows this script is capable of failing. See the
# README's "Proving the bound" section.
#
# The bound itself is lowered to PROBE_BG_MAX_S (default 120s) for the run, so
# the probe takes about three minutes rather than half an hour. Costs a few
# cents on a cheap model. It stops the session it spawns on every exit path,
# including Ctrl-C and an assertion failure.
#
# Exit codes: 0 = bound proven, 1 = assertion failed, 2 = could not set up.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- resolve the runner under test -----------------------------------
RUNNER_ARG="${1:-task-queue}"
case "$RUNNER_ARG" in
  */*)                    RUNNER_SH="$RUNNER_ARG"; RUNNER_NAME="$RUNNER_ARG" ;;
  task-queue|audit-queue) RUNNER_SH="$SKILL_DIR/../$RUNNER_ARG/run.sh"; RUNNER_NAME="$RUNNER_ARG" ;;
  *)
    echo "probe: unknown runner '$RUNNER_ARG' (expected task-queue, audit-queue, or a path to a run.sh)" >&2
    exit 2
    ;;
esac
if [[ ! -f "$RUNNER_SH" ]]; then
  echo "probe: no such runner script: $RUNNER_SH" >&2
  exit 2
fi

for tool in claude jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "probe: $tool is not on PATH" >&2; exit 2; }
done

# Source the runner so the assertions below run its REAL functions rather than
# a copy. Its source-guard stops before the polling loop, so nothing is
# dispatched and no task is claimed — the same way test-run.sh loads it. A
# sourced script sees the CALLER's positional parameters, so this probe's own
# `$1` lands in the runner's `$1`; both runners guard against that (in
# different shapes — see probe-completion-detection.sh) and
# `task-queue/test-run.sh` asserts it.
# shellcheck source=/dev/null
source "$RUNNER_SH"
trap - INT TERM HUP   # belt-and-suspenders: the runner registers its signal
                      # traps only in the executed section, so nothing is set.

# Lower the bound for this run. Assigned AFTER sourcing, so it overrides
# whatever default the runner set — and deliberately not exported, so nothing
# this probe spawns inherits it.
STALL_BG_MAX_S="${PROBE_BG_MAX_S:-120}"
BOUND="$STALL_BG_MAX_S"
POLL_S="${PROBE_POLL_S:-5}"
PROBE_MODEL="${PROBE_MODEL:-sonnet}"
# Ceiling on the watch. Generous relative to the bound: the daemon may re-invoke
# a quiet session with a "Continue from where you left off" nudge, and a session
# that answers one resets its own quiet clock, so the climb can need a second run
# at it. (Not observed in the 2026-07-31 measurement above, which climbed
# monotonically to 281s.)
WATCH_MAX_S="${PROBE_WATCH_MAX_S:-420}"
# How long to wait for the stopped session to actually reach a terminal state.
STOP_MAX_S="${PROBE_STOP_MAX_S:-60}"

SHORT_ID=""
cleanup() {
  if [[ -n "$SHORT_ID" ]]; then
    echo "probe: stopping session $SHORT_ID"
    claude stop "$SHORT_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "=================================================================="
echo "probe-persistent-inflight — runner: $RUNNER_NAME"
echo "  STALL_BG_MAX_S=${BOUND}s  poll=${POLL_S}s  model=$PROBE_MODEL"
echo "=================================================================="

# ---- dispatch ---------------------------------------------------------
# Three instructions here are load-bearing.
#
# PERSISTENT is what makes the Monitor never drain — a non-persistent one
# expires at its timeout and the count goes back to 0, which is an ordinary
# unarmed stall and proves nothing about the bound.
#
# A command that prints NOTHING keeps the session quiet: every line a monitor
# emits is a notification that re-invokes the session and resets its quiet
# clock, so a chatty watch would hold the climb below the bound forever.
#
# END THE TURN drops the session to tempo=idle. A session that keeps working
# stays at tempo=active, where check_stall_signature's FIRST gate returns
# not-a-stall and neither the guard nor its bound is ever reached — the same
# way the 2026-07-31 end-to-end run missed the window.
PROBE_PROMPT="Do exactly the following, and nothing else.

1. You may not have a Monitor tool loaded. If you do not already have one,
   call ToolSearch with the query \"select:Monitor\" to load its schema.
2. Call Monitor with these inputs:
     description: \"persistent no-op watch\"
     persistent: true
     command: while true; do sleep 60; done
   That command deliberately never prints anything and never exits.
3. Then STOP: end your turn right away. Do not poll it, do not sleep, do not
   check on it, do not run any other command, do not read or write any files,
   do not explain anything.

Later you may be re-invoked — by a notification, or by a \"Continue from where
you left off\" nudge. EVERY time that happens, do exactly this and nothing else:

  Reply with this single line of plain text:

      PROBE ACK

  Make NO tool call of any kind. Do not run commands. Do not investigate
  anything. Do not ask questions. Emit that one line and end your turn.

Emitting that line matters: a turn that ends with no text at all causes this
session to be closed out, and this probe needs it to stay open and quiet."

DISPATCH_OUT=$(mktemp)
claude --bg --name "probe-persistent-inflight" \
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
# Strip ANSI before parsing: `claude` colorizes the short id whenever
# FORCE_COLOR is set — which it is inside a Claude Code session — and a bare
# [a-f0-9]+ match then silently captures nothing.
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
STDERR_FILE=$(mktemp)
# One sample of the live session. Every input except S_VERDICT is read straight
# from the daemon and the JSONL — deliberately NOT from check_stall_signature —
# so that removing the bound changes the VERDICT while leaving the window
# definition intact. A probe that defined its window in terms of the function
# under test would report "window never reached" for a broken bound instead of
# reporting a violation, and a skipped assertion reads far too much like a
# passing one.
#
# stderr is captured rather than discarded: the line the bound prints on
# crossing is itself an assertion below, and this is the only place it can be
# observed live.
sample() {
  if [[ -z "$JSONL" || ! -f "$JSONL" ]]; then
    JSONL=$(find "$HOME/.claude/projects" -maxdepth 2 -name "${SHORT_ID}*.jsonl" \
              ! -path '*/subagents/*' 2>/dev/null | head -1)
  fi
  S_STATE=$(jq -r '.state // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
  S_TEMPO=$(jq -r '.tempo // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
  S_KINDS=$(jq -rc '.inFlight.kinds // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
  S_TASKS=$(worker_bg_task_count "$SHORT_ID") || S_TASKS="NA"
  S_QUIET=$(worker_quiet_seconds "$JSONL") || S_QUIET="NA"
  : > "$STDERR_FILE"
  if check_stall_signature "$SHORT_ID" "$JSONL" 2>"$STDERR_FILE"; then
    S_VERDICT="stall"
  else
    S_VERDICT="not-a-stall"
  fi
  S_STDERR=$(cat "$STDERR_FILE")
}

# True when the session is parked in the state the bound exists for: idle,
# non-terminal, and armed with work that is not going to drain.
armed_and_parked() {
  [[ "$S_TEMPO" == "idle" ]] || return 1
  case "$S_STATE" in done|stopped|failed|blocked) return 1 ;; esac
  [[ "$S_TASKS" =~ ^[0-9]+$ ]] || return 1
  (( S_TASKS > 0 )) || return 1
  [[ "$S_QUIET" =~ ^[0-9]+$ ]]
}

show() {
  printf '  %-8s state=%-8s tempo=%-7s tasks=%-3s kinds=%-26s quiet=%-4s -> %s\n' \
    "$(date +%H:%M:%S)" "$S_STATE" "$S_TEMPO" "$S_TASKS" "$S_KINDS" "$S_QUIET" "$S_VERDICT"
}

# ---- the watch --------------------------------------------------------
echo
echo "--- watching: a persistent Monitor keeps the count armed while quiet climbs"
echo "    below ${BOUND}s the guard must hold; past it, it must let go"

SAW_ARMED=0            # the count was ever positive
BELOW_SAMPLES=0        # parked, armed, quiet < bound
BELOW_VIOLATIONS=0     # ...where the guard nevertheless said "stall"
ABOVE_SAMPLES=0        # parked, armed, quiet >= bound
ABOVE_MISSES=0         # ...where the guard still said "not-a-stall"
MAX_QUIET_ARMED=0
DRAINED_WHILE_PARKED=0
CROSSING_SEEN=0        # the flip observed with the count still armed
CROSSING_LINE=""
WATCH_START=$(date +%s)

while (( $(date +%s) - WATCH_START < WATCH_MAX_S )); do
  sample
  show
  if [[ "$S_TASKS" =~ ^[0-9]+$ ]] && (( S_TASKS > 0 )); then
    SAW_ARMED=1
    if armed_and_parked; then
      (( S_QUIET > MAX_QUIET_ARMED )) && MAX_QUIET_ARMED=$S_QUIET
      if (( S_QUIET < BOUND )); then
        BELOW_SAMPLES=$(( BELOW_SAMPLES + 1 ))
        if [[ "$S_VERDICT" == "stall" ]]; then
          BELOW_VIOLATIONS=$(( BELOW_VIOLATIONS + 1 ))
          echo "           ^^ VIOLATION: inside the bound, yet the runner would take over"
        fi
      else
        ABOVE_SAMPLES=$(( ABOVE_SAMPLES + 1 ))
        if [[ "$S_VERDICT" == "stall" ]]; then
          if (( CROSSING_SEEN == 0 )); then
            CROSSING_SEEN=1
            CROSSING_LINE="$S_STDERR"
            echo "           ^^ the bound fired: takeover declared with tasks=$S_TASKS still armed"
            break
          fi
        else
          ABOVE_MISSES=$(( ABOVE_MISSES + 1 ))
          echo "           ^^ past the bound and still suppressed — the runner is waiting forever"
        fi
      fi
    fi
  elif (( SAW_ARMED )) && [[ "$S_TASKS" =~ ^[0-9]+$ ]] && (( S_TASKS == 0 )); then
    DRAINED_WHILE_PARKED=1
    echo "           ^^ the count DRAINED — the daemon does not hold it for a persistent Monitor"
    break
  fi
  case "$S_STATE" in
    done|stopped|failed) echo "  session reached terminal state $S_STATE"; break ;;
  esac
  sleep "$POLL_S"
done

# ---- the takeover actually recovers the session -----------------------
# Declaring a stall is a decision; what the runner then does is `claude stop`.
# A Monitor-armed session is exactly the shape that might not stop cleanly, so
# the recovery is exercised rather than assumed. (This probe calls
# check_stall_signature directly and never runs wait_for_bg_session, so the
# stop is issued here the way that caller issues it.)
RECOVERED=0
if (( CROSSING_SEEN )); then
  echo
  echo "--- takeover: \`claude stop\` must actually recover a Monitor-armed session"
  claude stop "$SHORT_ID" >/dev/null 2>&1 || true
  STOP_START=$(date +%s)
  while (( $(date +%s) - STOP_START < STOP_MAX_S )); do
    sleep 2
    S_STATE=$(jq -r '.state // "-"' "$STATE_FILE" 2>/dev/null || echo "-")
    case "$S_STATE" in
      done|stopped|failed) RECOVERED=1; break ;;
    esac
  done
  echo "  final state=$S_STATE after $(( $(date +%s) - STOP_START ))s"
fi
rm -f "$STDERR_FILE"

# ---- verdict ---------------------------------------------------------
echo
echo "=================================================================="
echo "observed window"
echo "  count ever armed ............................ $SAW_ARMED"
echo "  count drained while parked .................. $DRAINED_WHILE_PARKED"
echo "  parked+armed samples inside the bound ....... $BELOW_SAMPLES"
echo "  ...where the guard wrongly said stall ....... $BELOW_VIOLATIONS"
echo "  parked+armed samples past the bound ......... $ABOVE_SAMPLES"
echo "  ...still suppressed past it ................. $ABOVE_MISSES"
echo "  longest quiet while armed ................... ${MAX_QUIET_ARMED}s (bound ${BOUND}s)"
echo "  crossing observed ........................... $CROSSING_SEEN"
echo "=================================================================="

FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

# The premise comes first. If the daemon drains the count for a persistent
# Monitor, there is no hole here and nothing below means anything — that is a
# finding to report, not an assertion to squeeze past.
if (( DRAINED_WHILE_PARKED )); then
  fail "the daemon DRAINED inFlight for a persistent Monitor — the premise this bound rests on does not hold on this Claude Code build; report it rather than reading anything into the assertions below"
elif (( SAW_ARMED == 0 )); then
  fail "background work was never armed at all — did the session arm its Monitor? this run proves nothing"
else
  pass "a persistent Monitor held the count armed while the session sat quiet (up to ${MAX_QUIET_ARMED}s)"
fi

# Reached-the-state before verdicts, for the same reason: every assertion below
# is vacuously satisfiable by a session that never got there.
if (( BELOW_SAMPLES > 0 && BELOW_VIOLATIONS == 0 )); then
  pass "inside the bound the guard held ($BELOW_SAMPLES samples, no takeover)"
elif (( BELOW_VIOLATIONS > 0 )); then
  fail "the guard declared a stall in $BELOW_VIOLATIONS of $BELOW_SAMPLES samples INSIDE the bound — a healthy worker awaiting a backgrounded command would be killed"
else
  fail "no parked+armed sample was taken inside the bound — the hold half of the bound is unproven by this run"
fi

if (( CROSSING_SEEN )); then
  pass "past ${BOUND}s of quiet, with the count STILL armed, the guard declared a stall"
else
  fail "the guard never let go: $ABOVE_MISSES samples sat past the bound still suppressed (longest quiet ${MAX_QUIET_ARMED}s). An unbounded suppression is exactly this shape — the runner waits forever."
fi

case "$CROSSING_LINE" in
  *"still armed — past STALL_BG_MAX_S"*)
    pass "the takeover explained itself on stderr, distinguishably from an ordinary stall"
    echo "      $CROSSING_LINE"
    ;;
  "")
    (( CROSSING_SEEN )) && fail "the bound fired silently — an operator cannot tell a stuck counter from a stuck model"
    ;;
  *)
    fail "the bound fired with an unrecognized stderr line: $CROSSING_LINE"
    ;;
esac

if (( CROSSING_SEEN )); then
  if (( RECOVERED )); then
    pass "\`claude stop\` recovered the Monitor-armed session (state=$S_STATE)"
  else
    fail "the session did not reach a terminal state within ${STOP_MAX_S}s of \`claude stop\` (state=$S_STATE) — the takeover decision is right but the recovery it triggers does not land"
  fi
fi

echo
if (( FAILED )); then
  echo "PROBE FAILED — the $RUNNER_NAME suppression bound is NOT proven by this run."
  exit 1
fi
echo "PROBE PASSED — the $RUNNER_NAME suppression bound held below it and let go past it."
exit 0
