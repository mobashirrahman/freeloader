#!/usr/bin/env bash
# run-plan.sh <feature>
#
# Runs a whole plan in one call, so the orchestrating session does not have to
# drive it step by step: checks the plan, commits the planner's tests, then runs
# the tasks wave by wave, several at a time within a wave. A task that clashes
# with another at merge time is retried once. It stops after the first wave in
# which a task does not pass.
#
# Tasks that already passed are not run again, so after fixing a failed task
# this can simply be called again to carry on.
#
# A build can outlast the time a caller is allowed to block on one command, so
# the work happens in a detached driver. This call waits for it for at most
# plan.waitSec seconds. If the build is not finished by then it answers
# {"status": "running"} and leaves the driver going; calling again resumes the
# wait and never starts a second driver.
#
# Prints exactly one JSON line: every task's outcome, what is left, and whether
# the finished feature needs a final review.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

DRIVE=0
if [ "${1:-}" = "--drive" ]; then
  DRIVE=1
  shift
fi
[ $# -eq 1 ] || die "usage: run-plan.sh <feature>"
FEATURE=$1

need git jq opencode
valid_name "$FEATURE" || die "feature name may only contain letters, digits, '.', '_' and '-'"
load_repo

S="$FL_ROOT/scripts"
PLAN="$FL_DIR/plan/$FEATURE"
OUT="$FL_DIR/runs/$FEATURE/_plan"
PARALLEL="$(cfg '.plan.parallel')"
[ "$PARALLEL" -ge 1 ] 2>/dev/null || PARALLEL=1

if [ "$DRIVE" -eq 0 ]; then
  mkdir -p "$OUT"
  pid="$(cat "$OUT/driver.pid" 2>/dev/null)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$OUT/summary.json"
    # Its own process group and no hangup, so it outlives this call.
    set -m
    nohup "$0" --drive "$FEATURE" >"$OUT/summary.json" 2>"$OUT/driver.err" </dev/null &
    pid=$!
    set +m
    echo "$pid" >"$OUT/driver.pid"
  fi
  waited=0
  budget="$(cfg '.plan.waitSec')"
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$budget" ]; then
      total="$(find "$PLAN" -maxdepth 1 -name '*.md' | grep -c .)"
      passed=0
      for r in "$FL_DIR/runs/$FEATURE"/*/result.json; do
        [ -f "$r" ] && [ "$(jq -r '.status' "$r" 2>/dev/null)" = pass ] && passed=$((passed + 1))
      done
      jq -cn --arg feature "$FEATURE" --argjson passed "$passed" --argjson total "$total" \
        '{status: "running", feature: $feature, passed: $passed, total: $total}'
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  rm -f "$OUT/driver.pid"
  jq -e '.status' "$OUT/summary.json" >/dev/null 2>&1 \
    || die "the plan driver stopped without a result: $(tail -n 3 "$OUT/driver.err" 2>/dev/null)"
  cat "$OUT/summary.json"
  [ "$(jq -r '.status' "$OUT/summary.json")" = pass ]
  exit $?
fi

CHECK="$("$S/check-plan.sh" "$FEATURE" 2>/dev/null)"
jq -e '.status' >/dev/null 2>&1 <<<"$CHECK" || die "could not check the plan for '$FEATURE'"
if [ "$(jq -r '.status' <<<"$CHECK")" != ok ]; then
  jq -c --arg feature "$FEATURE" '{status: "plan_invalid", feature: $feature, problems}' <<<"$CHECK"
  exit 1
fi

"$S/feature.sh" commit-tests "$FEATURE" >/dev/null || die "could not commit the planner's tests"
mkdir -p "$OUT"

run_one() { "$S/run-task.sh" "$FEATURE" "$PLAN/$1.md" >"$OUT/$1.json" 2>"$OUT/$1.err" </dev/null; }
status_of() { jq -r '.status // "error"' "$OUT/$1.json" 2>/dev/null || echo error; }

waves="$(jq '.waves | length' <<<"$CHECK")"
w=0
stopped=0
while [ "$w" -lt "$waves" ] && [ "$stopped" -eq 0 ]; do
  ids="$(jq -r ".waves[$w][]" <<<"$CHECK")"
  running=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    run_one "$id" &
    running=$((running + 1))
    if [ "$running" -ge "$PARALLEL" ]; then
      wait
      running=0
    fi
  done <<<"$ids"
  wait

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # Passed alone but clashed with a sibling: run again on top of what has merged.
    case "$(status_of "$id")" in
      conflict|integration_fail) run_one "$id" ;;
    esac
    [ "$(status_of "$id")" = pass ] || stopped=1
  done <<<"$ids"
  w=$((w + 1))
done

RESULTS="{}"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  r="$FL_DIR/runs/$FEATURE/$id/result.json"
  # A task that failed before producing a result file still reported on stdout.
  [ -f "$r" ] || r="$OUT/$id.json"
  if jq -e '.status' "$r" >/dev/null 2>&1; then
    RESULTS="$(jq -c --arg id "$id" --slurpfile r "$r" '. + {($id): $r[0]}' <<<"$RESULTS")"
  fi
done <<<"$(jq -r '.tasks[].id' <<<"$CHECK")"

DIFF="{}"
if [ "$(jq '[.[] | select(.status == "pass")] | length' <<<"$RESULTS")" -eq "$(jq '.tasks | length' <<<"$CHECK")" ]; then
  DIFF="$("$S/feature.sh" diff "$FEATURE" 2>/dev/null)" || DIFF="{}"
fi

jq -cn --arg feature "$FEATURE" --arg branch "$(feature_branch "$FEATURE")" \
  --argjson check "$CHECK" --argjson results "$RESULTS" --argjson diff "$DIFF" \
  --arg mode "$(cfg '.finalReview.mode')" --argjson min "$(cfg '.finalReview.minTasks')" '
  ($check.tasks | map(. as $t | ($results[$t.id] // {status: "pending"}) as $r
    | {id: $t.id, tier: $t.tier, status: $r.status}
      + (if $r.status == "pass" then {model: $r.model, attempts: $r.attempts}
         elif $r.status == "pending" then {}
         else {stage: $r.stage, detail: (($r.detail // $r.error // "")[0:600]), worktree: $r.worktree}
         end))) as $tasks
  | ($tasks | map(select(.status == "pass"))) as $passed
  | (($tasks | map(select(.tier == "hard")) | length) > 0) as $hard
  | (($passed | map(select(.model == "external")) | length) > 0) as $escalated
  | (if $mode == "always" then "always requested"
     elif $mode == "never" then null
     elif ($tasks | length) >= $min then "the plan has \($tasks | length) tasks"
     elif $hard then "the plan has a hard task"
     elif $escalated then "a task needed escalation"
     else null end) as $why
  | {status: (if ($passed | length) == ($tasks | length) then "pass" else "incomplete" end),
     feature: $feature, branch: $branch,
     passed: ($passed | length), total: ($tasks | length),
     tasks: $tasks,
     failed: ($tasks | map(select(.status != "pass" and .status != "pending") | .id)),
     pending: ($tasks | map(select(.status == "pending") | .id)),
     review: (if $why then "needed" else "skip" end)}
    + (if $why then {reviewReason: $why} else {} end)
    + (if $diff.diff then {diff: $diff.diff, stat: $diff.stat} else {} end)'
