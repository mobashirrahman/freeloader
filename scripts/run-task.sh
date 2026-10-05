#!/usr/bin/env bash
# run-task.sh [--verify-only] [--force] <feature> <task-file>
#
# Runs one task end to end:
#   coder (opencode) -> scope check -> gate (acceptance command) -> reviewer (opencode)
# with feedback rounds and a model fallback chain, then merges the result into the
# feature's integration branch.
#
# Depending on the task's tier, several lanes race: each lane is its own git
# worktree with its own share of the coder models, and the first lane to pass wins.
#
# Prints exactly one JSON line; everything else goes to .freeloader/runs/<feature>/<task-id>/.
#
# --verify-only skips the coder and reviewer and just gates and merges whatever is
#               already in the task's worktree. Use it after fixing a failed task
#               by other means.
# --force       re-run a task that has already passed and merged.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

VERIFY_ONLY=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=1 ;;
    --force) FORCE=1 ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
  shift
done
[ $# -eq 2 ] || die "usage: run-task.sh [--verify-only] [--force] <feature> <task-file>"
FEATURE=$1
TASK=$2

need git jq opencode
valid_name "$FEATURE" || die "feature name may only contain letters, digits, '.', '_' and '-'"
[ -f "$TASK" ] || die "task file not found: $TASK"
TASK="$(cd "$(dirname "$TASK")" && pwd)/$(basename "$TASK")"

load_repo
build_role_configs

# --- task file ---------------------------------------------------------------

ID="$(task_field "$TASK" id)"
ACCEPT="$(task_field "$TASK" accept)"
FILES="$(task_list "$TASK" files)"
TITLE="$(task_title "$TASK")"
[ -n "$TITLE" ] || TITLE="$ID"

valid_name "$ID" || die "task file needs a frontmatter 'id' made of letters, digits, '.', '_' and '-'"
[ "$ID" != "main" ] && [ "$ID" != "_main" ] || die "task id '$ID' is reserved"
[ -n "$ACCEPT" ] || die "task file needs a frontmatter 'accept' command"
TIER="$(task_field "$TASK" tier)"
[ -n "$TIER" ] || TIER=normal
case "$TIER" in
  easy|normal|hard) ;;
  *) die "task tier must be easy, normal or hard, not '$TIER'" ;;
esac

CODER_TIMEOUT="$(cfg '.coder.timeoutSec')"
ROUNDS="$(cfg '.coder.roundsPerModel')"
MAX_ATTEMPTS="$(cfg '.coder.maxAttempts')"
RACE="$(cfg ".tiers.$TIER.race // 1")"
# A tier's own models go first; the general chain follows, best performers first.
CODER_MODELS="$( { cfg ".tiers.$TIER.models // [] | .[]"; ordered_models "$(cfg '.coder.models[]')"; } | awk 'NF && !seen[$0]++')"
REVIEW_MODELS="$(cfg '.reviewer.models[]')"
REVIEW_REQUIRED="$(cfg '.reviewer.required')"
REVIEW_TIMEOUT="$(cfg '.reviewer.timeoutSec')"
MAX_DIFF="$(cfg '.reviewer.maxDiffBytes')"
GATE_TIMEOUT="$(cfg '.gate.timeoutSec')"
FEEDBACK_LINES="$(cfg '.gate.feedbackLines')"
GATE_CMDS="$ACCEPT
$(cfg '.gate.commands[]')"
IGNORE="$(cfg '.scope.ignore[]')"
PROTECT="$(task_list "$TASK" protect)
$(cfg '.scope.protect[]')"

# --- paths --------------------------------------------------------------------

ensure_feature "$FEATURE"
MAIN_BRANCH="$(feature_branch "$FEATURE")"
MAIN_WT="$(feature_worktree "$FEATURE")"
WT_ROOT="$FL_DIR/worktrees/$FEATURE"
RUN_ROOT="$FL_DIR/runs/$FEATURE/$ID"
START="$(date +%s)"

# Lane 1 uses the task's own names; extra lanes get a --rN suffix.
lane_wt() { if [ "$1" -eq 1 ]; then echo "$WT_ROOT/$ID"; else echo "$WT_ROOT/$ID--r$1"; fi; }
lane_branch() { if [ "$1" -eq 1 ]; then echo "freeloader/$FEATURE/$ID"; else echo "freeloader/$FEATURE/$ID--r$1"; fi; }

# A task that already passed and is merged is not run again, so a resumed build
# can call every task without redoing finished work.
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -f "$RUN_ROOT/result.json" ]; then
  done_commit="$(jq -r 'select(.status == "pass") | .commit // empty' "$RUN_ROOT/result.json" 2>/dev/null)"
  if [ -n "$done_commit" ] && git -C "$REPO" merge-base --is-ancestor "$done_commit" "$MAIN_BRANCH" 2>/dev/null; then
    jq -c '. + {cached: true}' "$RUN_ROOT/result.json"
    exit 0
  fi
fi

# --- steps -------------------------------------------------------------------

IN_LANE=0
LANES=1
STAGE=""
MODEL=""
ATTEMPTS=0
DETAIL=""
REVIEW="none"
ISSUES="[]"
CHANGED=""
COMMIT=""
WT="$(lane_wt 1)"
BRANCH="$(lane_branch 1)"
RUN="$RUN_ROOT"

emit() {
  local json
  json="$(jq -cn --arg status "$1" --arg id "$ID" --arg feature "$FEATURE" --arg tier "$TIER" \
    --arg stage "$STAGE" --arg model "$MODEL" --argjson attempts "$ATTEMPTS" \
    --argjson lanes "$LANES" --argjson seconds "$(($(date +%s) - START))" \
    --arg branch "$BRANCH" --arg worktree "$WT" --arg commit "$COMMIT" \
    --arg review "$REVIEW" --argjson issues "$ISSUES" \
    --arg files "$CHANGED" --arg detail "$DETAIL" --arg logs "$RUN_ROOT" '
    {status: $status, id: $id, feature: $feature, tier: $tier, stage: $stage, model: $model,
     attempts: $attempts, lanes: $lanes, seconds: $seconds, branch: $branch,
     worktree: $worktree, commit: $commit, review: $review, issues: $issues,
     files: ($files | split("\n") | map(select(. != ""))),
     detail: $detail[0:1500], logs: $logs}')"
  if [ "$IN_LANE" -eq 0 ]; then
    printf '%s\n' "$json" >"$RUN_ROOT/result.json"
    ledger "$(jq -c '{ts: (now | floor), kind: "task", feature, id, tier, status, stage, model, attempts, lanes, seconds}' <<<"$json")"
  fi
  printf '%s\n' "$json"
}

# Stages the worktree, drops build junk, reverts protected files, and sets CHANGED,
# PROTECTED_HIT and OUT_OF_SCOPE.
stage_changes() {
  local f
  git -C "$WT" add -A
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    matches_any "$f" "$IGNORE" && git -C "$WT" reset -q -- "$f"
  done < <(git -C "$WT" diff --cached --name-only "$BASE")
  CHANGED="$(git -C "$WT" diff --cached --name-only "$BASE")"
  # Protected files define what correct means, so any change to them is discarded
  # here rather than negotiated with the coder.
  PROTECTED_HIT=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    matches_any "$f" "$PROTECT" || continue
    PROTECTED_HIT="$PROTECTED_HIT$f
"
    if git -C "$WT" cat-file -e "$BASE:$f" 2>/dev/null; then
      git -C "$WT" checkout -q "$BASE" -- "$f"
    else
      git -C "$WT" rm -q -f --cached -- "$f"
      rm -f "$WT/$f"
    fi
  done <<<"$CHANGED"
  CHANGED="$(git -C "$WT" diff --cached --name-only "$BASE")"
  OUT_OF_SCOPE=""
  [ -n "$FILES" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    matches_any "$f" "$FILES" || OUT_OF_SCOPE="$OUT_OF_SCOPE$f
"
  done <<<"$CHANGED"
}

# run_gate <dir> <log>; on failure sets GATE_FAILED to the failing command.
run_gate() {
  local dir=$1 log=$2 cmd rc
  : >"$log"
  while IFS= read -r cmd <&4; do
    [ -n "$cmd" ] || continue
    echo "\$ $cmd" >>"$log"
    rc=0
    (cd "$dir" && with_timeout "$GATE_TIMEOUT" bash -c "$cmd") >>"$log" 2>&1 </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      is_timeout_rc "$rc" && echo "(timed out after ${GATE_TIMEOUT}s)" >>"$log"
      GATE_FAILED="$cmd"
      return 1
    fi
  done 4<<<"$GATE_CMDS"
  return 0
}

coder_prompt() {
  echo "# Task"
  task_body "$TASK"
  echo
  echo "# Allowed files"
  if [ -n "$FILES" ]; then echo "$FILES"; else echo "(no restriction)"; fi
  echo
  if [ -n "$(printf '%s' "$PROTECT" | tr -d '[:space:]')" ]; then
    echo "# Protected files (read them, never change them)"
    printf '%s\n' "$PROTECT" | grep .
    echo
  fi
  echo "# Acceptance command"
  echo "$ACCEPT"
  if [ -n "$1" ]; then
    echo
    echo "# Feedback on your previous attempt"
    echo "Your earlier changes are still in the working tree. Fix these problems:"
    echo "$1"
  fi
}

# Sets REVIEW to pass | fail | skipped and ISSUES to a JSON array.
run_review() {
  local n=$1 model prompt json verdict
  prompt="# Task
$(task_body "$TASK")

# Diff
$(git -C "$WT" diff --cached "$BASE" | head -c "$MAX_DIFF")"
  REVIEW="skipped"
  ISSUES="[]"
  while IFS= read -r model <&5; do
    [ -n "$model" ] || continue
    run_opencode reviewer "$model" "$REVIEW_TIMEOUT" "$RUN/review-$n.jsonl" "$prompt"
    [ "$OC_STATUS" = ok ] || continue
    json="$(printf '%s' "$OC_TEXT" | extract_json)" || continue
    verdict="$(jq -r '.verdict | ascii_downcase' <<<"$json" 2>/dev/null)" || continue
    case "$verdict" in
      pass|fail)
        REVIEW="$verdict"
        ISSUES="$(jq -c '.issues // [] | if type == "array" then . else [] end' <<<"$json")"
        printf '%s\n' "$json" >"$RUN/review-$n.json"
        return 0
        ;;
    esac
  # A review is optional, so reviewers that are cooling down are simply not asked.
  done 5<<<"$(ready_models "$REVIEW_MODELS")"
  return 0
}

# check <attempt-number>: scope, gate, and review for what is in the worktree.
# Returns 0 on pass; otherwise sets STAGE and FEEDBACK.
check() {
  check_steps "$1" && return 0
  [ -z "$PROTECTED_HIT" ] || FEEDBACK="$FEEDBACK

Your changes to these protected files were discarded. Do not edit them; fix the implementation instead:
$PROTECTED_HIT"
  return 1
}

check_steps() {
  local n=$1
  stage_changes
  if [ -z "$CHANGED" ]; then
    STAGE=coder
    FEEDBACK="You made no changes to any file. Implement the task by editing the allowed files."
    return 1
  fi
  if [ -n "$OUT_OF_SCOPE" ]; then
    STAGE=scope
    FEEDBACK="You changed files outside the allowed list. Undo your changes to these files:
$OUT_OF_SCOPE"
    return 1
  fi
  if ! run_gate "$WT" "$RUN/gate-$n.log"; then
    STAGE=gate
    FEEDBACK="This command failed: $GATE_FAILED
Last lines of its output:
$(tail -n "$FEEDBACK_LINES" "$RUN/gate-$n.log")"
    return 1
  fi
  [ "$VERIFY_ONLY" -eq 1 ] && return 0
  run_review "$n"
  if [ "$REVIEW" = fail ]; then
    STAGE=review
    FEEDBACK="A reviewer rejected the change. Fix these issues:
$(jq -r '.[] | "- \(.file // "?"): \(.problem // "") Fix: \(.fix // "")"' <<<"$ISSUES")"
    return 1
  fi
  if [ "$REVIEW" = skipped ] && [ "$REVIEW_REQUIRED" = true ]; then
    STAGE=review
    FEEDBACK="No reviewer model returned a usable verdict."
    return 1
  fi
  return 0
}

# --- one lane ------------------------------------------------------------------

# lane_main <n> <newline-separated models>: runs in a background subshell. Works
# through its models in its own worktree, commits on a pass, prints one JSON line.
lane_main() {
  local n=$1 models=$2 model round t0
  IN_LANE=1
  WT="$(lane_wt "$n")"
  BRANCH="$(lane_branch "$n")"
  RUN="$RUN_ROOT/r$n"
  mkdir -p "$RUN"
  run_setup "$WT"
  cd "$WT" || die "cannot enter worktree $WT"
  PASSED=0
  FEEDBACK=""
  while IFS= read -r model <&3; do
    [ -n "$model" ] || continue
    [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ] || break
    MODEL="$model"
    # Each model starts from a clean tree rather than inheriting a broken attempt.
    git -C "$WT" reset -q --hard "$BASE"
    git -C "$WT" clean -qfd
    FEEDBACK=""
    round=0
    while [ "$round" -lt "$ROUNDS" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
      round=$((round + 1))
      ATTEMPTS=$((ATTEMPTS + 1))
      t0="$(date +%s)"
      run_opencode coder "$model" "$CODER_TIMEOUT" "$RUN/coder-$ATTEMPTS.jsonl" \
        "$(coder_prompt "$FEEDBACK")"
      if [ "$OC_STATUS" = quota ] || [ "$OC_STATUS" = refused ] || [ "$OC_STATUS" = error ]; then
        STAGE=coder
        FEEDBACK="coder model $model failed: $OC_STATUS${OC_ERROR:+ ($OC_ERROR)}"
        ledger_attempt "$model" "$OC_STATUS" "$t0"
        # A model that never ran does not use up one of the task's attempts.
        ATTEMPTS=$((ATTEMPTS - 1))
        break
      fi
      if check "$ATTEMPTS"; then
        ledger_attempt "$model" pass "$t0"
        PASSED=1
        break 2
      fi
      ledger_attempt "$model" "$STAGE" "$t0"
      [ "$OC_STATUS" = timeout ] && FEEDBACK="You ran out of time before finishing.
$FEEDBACK"
    done
  done 3<<<"$models"

  if [ "$PASSED" -ne 1 ]; then
    DETAIL="$FEEDBACK"
    emit fail
    return 1
  fi
  git_commit "$WT" "freeloader($ID): $TITLE" || { DETAIL="commit failed"; emit error; return 2; }
  COMMIT="$(git -C "$WT" rev-parse HEAD)"
  emit pass
}

ledger_attempt() {
  ledger "$(jq -cn --arg feature "$FEATURE" --arg id "$ID" --arg tier "$TIER" --arg model "$1" \
    --arg outcome "$2" --argjson seconds "$(($(date +%s) - $3))" \
    '{ts: (now | floor), kind: "attempt", feature: $feature, id: $id, tier: $tier,
      model: $model, outcome: $outcome, seconds: $seconds}')"
}

remove_lane() {
  git -C "$REPO" worktree remove --force "$(lane_wt "$1")" >/dev/null 2>&1 || rm -rf "$(lane_wt "$1")"
  git -C "$REPO" branch -q -D "$(lane_branch "$1")" >/dev/null 2>&1
}

# --- run ---------------------------------------------------------------------

PASSED=0
FEEDBACK=""
LANE_PIDS=""
stop_lanes() {
  local pid
  for pid in $LANE_PIDS; do
    # Each lane is its own process group, so this also stops its opencode.
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  done
  LANE_PIDS=""
}
trap 'stop_lanes; release_lock' EXIT
trap 'exit 130' INT TERM

if [ "$VERIFY_ONLY" -eq 1 ]; then
  [ -d "$WT" ] || die "no worktree for task $ID; run it without --verify-only first"
  BASE="$(git -C "$WT" merge-base HEAD "$MAIN_BRANCH")"
  RUN="$RUN_ROOT/verify"
  mkdir -p "$RUN"
  MODEL="external"
  ATTEMPTS=1
  cd "$WT" || die "cannot enter worktree $WT"
  if check 1; then
    if ! git -C "$WT" diff --cached --quiet; then
      git_commit "$WT" "freeloader($ID): $TITLE" || { DETAIL="commit failed"; emit error; exit 2; }
    fi
    COMMIT="$(git -C "$WT" rev-parse HEAD)"
    PASSED=1
  fi
else
  rm -rf "$RUN_ROOT"
  mkdir -p "$RUN_ROOT"
  MODELS="$(usable_models "$CODER_MODELS")"
  count="$(printf '%s\n' "$MODELS" | grep -c .)"
  [ "$count" -gt 0 ] || die "no coder models configured"
  LANES="$RACE"
  [ "$LANES" -le "$count" ] || LANES="$count"
  [ "$LANES" -ge 1 ] || LANES=1

  acquire_lock _git
  for d in "$WT_ROOT/$ID" "$WT_ROOT/$ID"--r*; do
    [ -d "$d" ] || continue
    git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
  done
  git -C "$REPO" worktree prune
  git -C "$REPO" for-each-ref --format='%(refname:short)' \
    "refs/heads/freeloader/$FEATURE/$ID" "refs/heads/freeloader/$FEATURE/$ID--r*" | while IFS= read -r b; do
    git -C "$REPO" branch -q -D "$b" >/dev/null 2>&1
  done
  BASE="$(git -C "$MAIN_WT" rev-parse HEAD)"
  n=1
  while [ "$n" -le "$LANES" ]; do
    git -C "$REPO" worktree add -q -b "$(lane_branch "$n")" "$(lane_wt "$n")" "$BASE" >&2 \
      || die "cannot create worktree $(lane_wt "$n")"
    n=$((n + 1))
  done
  release_lock

  # Deal the models out to the lanes in turn, so no two lanes share a model's quota.
  set -m
  n=1
  while [ "$n" -le "$LANES" ]; do
    lane_models="$(printf '%s\n' "$MODELS" | awk -v k="$LANES" -v n="$n" 'NF { if (i++ % k == n - 1) print }')"
    (lane_main "$n" "$lane_models") >"$RUN_ROOT/lane-$n.json" 2>"$RUN_ROOT/lane-$n.err" &
    LANE_PIDS="$LANE_PIDS $!"
    n=$((n + 1))
  done
  set +m

  lane_status() { jq -r '.status // empty' "$RUN_ROOT/lane-$1.json" 2>/dev/null | head -1; }
  WINNER=0
  while [ "$WINNER" -eq 0 ]; do
    alive=0
    for pid in $LANE_PIDS; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    n=1
    while [ "$n" -le "$LANES" ]; do
      if [ "$(lane_status "$n")" = pass ]; then WINNER=$n; break; fi
      n=$((n + 1))
    done
    [ "$alive" -eq 1 ] || break
    [ "$WINNER" -ne 0 ] || sleep 1
  done
  stop_lanes
  wait 2>/dev/null

  # Keep the winner, or failing that the lane that got furthest, and drop the rest.
  CHOSEN=$WINNER
  if [ "$CHOSEN" -eq 0 ]; then
    best=-1
    n=1
    while [ "$n" -le "$LANES" ]; do
      case "$(jq -r '.stage // empty' "$RUN_ROOT/lane-$n.json" 2>/dev/null | head -1)" in
        review) rank=4 ;; gate) rank=3 ;; scope) rank=2 ;; coder) rank=1 ;; *) rank=0 ;;
      esac
      if [ "$rank" -gt "$best" ]; then best=$rank; CHOSEN=$n; fi
      n=$((n + 1))
    done
  fi
  total=0
  n=1
  while [ "$n" -le "$LANES" ]; do
    a="$(jq -r '.attempts // 0' "$RUN_ROOT/lane-$n.json" 2>/dev/null | head -1)"
    total=$((total + ${a:-0}))
    n=$((n + 1))
  done

  acquire_lock _git
  n=1
  while [ "$n" -le "$LANES" ]; do
    [ "$n" -eq "$CHOSEN" ] || remove_lane "$n"
    n=$((n + 1))
  done
  if [ "$CHOSEN" -ne 1 ]; then
    git -C "$REPO" worktree move "$(lane_wt "$CHOSEN")" "$(lane_wt 1)" >&2 \
      && git -C "$REPO" branch -q -m "$(lane_branch "$CHOSEN")" "$(lane_branch 1)"
  fi
  release_lock

  R="$(cat "$RUN_ROOT/lane-$CHOSEN.json" 2>/dev/null)"
  if ! jq -e '.status' >/dev/null 2>&1 <<<"$R"; then
    die "lane $CHOSEN produced no result: $(tail -n 3 "$RUN_ROOT/lane-$CHOSEN.err" 2>/dev/null)"
  fi
  STAGE="$(jq -r '.stage' <<<"$R")"
  MODEL="$(jq -r '.model' <<<"$R")"
  REVIEW="$(jq -r '.review' <<<"$R")"
  ISSUES="$(jq -c '.issues' <<<"$R")"
  CHANGED="$(jq -r '.files[]' <<<"$R")"
  COMMIT="$(jq -r '.commit' <<<"$R")"
  FEEDBACK="$(jq -r '.detail // .error // ""' <<<"$R")"
  ATTEMPTS=$total
  RUN="$RUN_ROOT"
  [ "$WINNER" -eq 0 ] || PASSED=1
  if [ "$(jq -r '.status' <<<"$R")" = error ]; then
    DETAIL="$FEEDBACK"
    emit error
    exit 2
  fi
fi

if [ "$PASSED" -ne 1 ]; then
  DETAIL="$FEEDBACK"
  emit fail
  exit 1
fi

# --- merge -------------------------------------------------------------------

STAGE=merge
acquire_lock "$FEATURE"

PRE="$(git -C "$MAIN_WT" rev-parse HEAD)"
if ! git -C "$MAIN_WT" merge -q --no-edit --no-verify "$BRANCH" >"$RUN_ROOT/merge.log" 2>&1; then
  git -C "$MAIN_WT" merge --abort >/dev/null 2>&1
  DETAIL="merge conflict with $MAIN_BRANCH:
$(tail -n 20 "$RUN_ROOT/merge.log")"
  emit conflict
  exit 1
fi

# If other tasks landed since this one branched, prove the combination still passes.
if [ "$PRE" != "$BASE" ] && ! run_gate "$MAIN_WT" "$RUN_ROOT/gate-merged.log"; then
  git -C "$MAIN_WT" reset -q --hard "$PRE"
  DETAIL="passed alone but failed after merging with other tasks. Command: $GATE_FAILED
$(tail -n "$FEEDBACK_LINES" "$RUN_ROOT/gate-merged.log")"
  emit integration_fail
  exit 1
fi

release_lock
cd "$REPO" || true
acquire_lock _git
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
release_lock
STAGE="done"
emit pass
