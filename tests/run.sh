#!/usr/bin/env bash
# End-to-end tests for the task runner. They drive the real scripts against real
# git repositories, with tests/stub/opencode standing in for the models.
#
#   tests/run.sh            run everything
#   tests/run.sh race       run the tests whose name contains "race"

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"
FILTER="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/stub:$PATH"
export FAKE_STATE="$TMP/state"
# The suite must not depend on, or write to, the developer's git identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PASSED=0
FAILED=0
CURRENT=""

eq() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL %s: %s\n       expected: %s\n       actual:   %s\n' "$CURRENT" "$1" "$2" "$3"
  fi
}

has() { # <what> <needle> <haystack>
  case "$3" in
    *"$2"*) PASSED=$((PASSED + 1)) ;;
    *)
      FAILED=$((FAILED + 1))
      printf '  FAIL %s: %s\n       expected to contain: %s\n       actual: %s\n' "$CURRENT" "$1" "$2" "$3"
      ;;
  esac
}

# Starts a fresh repository with one commit and feature "f", and cds into it.
new_repo() {
  REPO="$TMP/repo-$RANDOM$RANDOM"
  rm -rf "$FAKE_STATE"
  mkdir -p "$REPO" "$FAKE_STATE"
  cd "$REPO" || exit 1
  git init -q -b main
  echo base >shared.txt
  git add -A
  git -c user.name=test -c user.email=test@example.com commit -qm init
  [ -z "${1:-}" ] || echo "$1" >freeloader.config.json
  "$S/feature.sh" start f "Build the thing" >/dev/null
  PLAN=.freeloader/plan/f
  MAIN_WT=.freeloader/worktrees/f/_main
}

# task <id> <accept> <files,csv> [extra frontmatter lines]
task() {
  {
    echo "---"
    echo "id: $1"
    echo "accept: $2"
    echo "files:"
    echo "$3" | tr ',' '\n' | sed 's/^/  - /'
    [ -z "${4:-}" ] || printf '%s\n' "$4"
    echo "---"
    echo "# Task $1"
    echo "Do the thing."
  } >"$PLAN/$1.md"
}

run() { "$S/run-task.sh" "$@" 2>/dev/null; }
field() { jq -r "$1" <<<"$2"; }
on_main() { git show "freeloader/f/main:$1" 2>/dev/null; }

t() { # <name> <function>
  case "$1" in *"$FILTER"*) ;; *) return 0 ;; esac
  CURRENT="$1"
  local before=$FAILED
  "$2"
  if [ "$FAILED" -eq "$before" ]; then echo "ok   $1"; else echo "FAIL $1"; fi
}

# --- plan check --------------------------------------------------------------

plan_ok() {
  new_repo
  task a 'true' a.txt
  task b 'true' b.txt
  task c 'true' c.txt,a.txt 'depends:
  - a
  - b'
  local out
  out="$("$S/check-plan.sh" f)"
  eq status ok "$(field .status "$out")"
  eq waves '[["a","b"],["c"]]' "$(field '.waves | tostring' "$out")"
}

plan_problems() {
  new_repo
  task a 'true' src/
  task b 'true' src/b.py
  task c '' c.txt 'depends:
  - nope'
  task d 'true' d.txt 'tier: extreme'
  task e 'true' e.txt 'protect:
  - tests/missing.py'
  local out
  out="$("$S/check-plan.sh" f | jq -r '.status, .problems[]')"
  has status fail "$out"
  has overlap "a and b can run in parallel but both may edit" "$out"
  has "missing accept" "c: missing 'accept' command" "$out"
  has "unknown dependency" "c: depends on unknown task nope" "$out"
  has "bad tier" "d: tier must be easy, normal or hard" "$out"
  has "missing protected file" "e: protected path 'tests/missing.py' does not exist" "$out"
}

plan_cycle() {
  new_repo
  task a 'true' a.txt 'depends:
  - b'
  task b 'true' b.txt 'depends:
  - a'
  has cycle "dependency cycle among: a, b" "$("$S/check-plan.sh" f | jq -r '.problems[]')"
}

# --- one task ----------------------------------------------------------------

task_passes() {
  new_repo
  task a 'grep -q hello out.txt' out.txt 'tier: easy'
  local out
  out="$(FAKE_CODER_CMD='echo hello > out.txt' run f "$PLAN/a.md")"
  eq status pass "$(field .status "$out")"
  eq review pass "$(field .review "$out")"
  eq "merged content" hello "$(on_main out.txt)"
  eq "worktree removed" "" "$(ls .freeloader/worktrees/f | grep -v _main)"
  eq "user checkout untouched" "" "$(git status --short | grep -v freeloader.config.json)"
}

gate_feedback_reaches_coder() {
  new_repo
  task a 'grep -q right out.txt' out.txt 'tier: easy'
  local out
  out="$(FAKE_CODER_CMD='if echo "$FAKE_PROMPT" | grep -q "This command failed"; then echo right > out.txt; else echo wrong > out.txt; fi' run f "$PLAN/a.md")"
  eq status pass "$(field .status "$out")"
  eq attempts 2 "$(field .attempts "$out")"
}

review_feedback_reaches_coder() {
  new_repo
  task a 'test -s greet.txt' greet.txt 'tier: easy'
  local out
  out="$(FAKE_REVIEWS=fail,pass FAKE_CODER_CMD='if echo "$FAKE_PROMPT" | grep -q "add the word please"; then echo "hello please" > greet.txt; else echo hello > greet.txt; fi' run f "$PLAN/a.md")"
  eq status pass "$(field .status "$out")"
  eq attempts 2 "$(field .attempts "$out")"
  eq "merged content" "hello please" "$(on_main greet.txt)"
}

out_of_scope_fails() {
  new_repo '{"coder":{"models":["m/one"],"roundsPerModel":1}}'
  task a 'true' a.txt
  local out
  out="$(FAKE_CODER_CMD='echo x > a.txt; echo x > sneaky.txt' run f "$PLAN/a.md")"
  eq status fail "$(field .status "$out")"
  eq stage scope "$(field .stage "$out")"
  has detail sneaky.txt "$(field .detail "$out")"
}

protected_edits_are_discarded() {
  new_repo
  mkdir -p "$MAIN_WT/tests"
  echo 'grep -q impl shared.txt' >"$MAIN_WT/tests/check.sh"
  "$S/feature.sh" commit-tests f >/dev/null
  task a 'sh tests/check.sh' shared.txt 'tier: easy
protect:
  - tests/check.sh'
  local out
  out="$(FAKE_CODER_CMD='if echo "$FAKE_PROMPT" | grep -q "protected files were discarded"; then echo impl >> shared.txt; else echo true > tests/check.sh; echo x >> shared.txt; fi' run f "$PLAN/a.md")"
  eq status pass "$(field .status "$out")"
  eq attempts 2 "$(field .attempts "$out")"
  eq "test file unchanged" 'grep -q impl shared.txt' "$(on_main tests/check.sh)"
  eq "only the implementation committed" '["shared.txt"]' "$(field '.files | tostring' "$out")"
}

verify_only_after_failure() {
  new_repo '{"coder":{"models":["m/one"],"roundsPerModel":1}}'
  task a 'grep -q good a.txt' a.txt
  local out
  out="$(FAKE_CODER_CMD='echo bad > a.txt' run f "$PLAN/a.md")"
  eq "first status" fail "$(field .status "$out")"
  eq "first stage" gate "$(field .stage "$out")"
  echo good >"$(field .worktree "$out")/a.txt"
  out="$(run --verify-only f "$PLAN/a.md")"
  eq "verify status" pass "$(field .status "$out")"
  eq "verify model" external "$(field .model "$out")"
  eq "merged content" good "$(on_main a.txt)"
}

cached_pass_is_not_rerun() {
  new_repo
  task a 'test -f a.txt' a.txt 'tier: easy'
  FAKE_CODER_CMD='echo x > a.txt' run f "$PLAN/a.md" >/dev/null
  : >"$FAKE_STATE/calls"
  local out
  out="$(run f "$PLAN/a.md")"
  eq cached true "$(field .cached "$out")"
  eq "no model called" "" "$(cat "$FAKE_STATE/calls")"
  out="$(FAKE_CODER_CMD='echo y > a.txt' run --force f "$PLAN/a.md")"
  eq "forced status" pass "$(field .status "$out")"
  eq "forced content" y "$(on_main a.txt)"
}

bad_task_file_is_an_error() {
  new_repo
  printf -- '---\nid: has space\n---\nx\n' >"$PLAN/bad.md"
  eq status error "$(field .status "$(run f "$PLAN/bad.md")")"
}

# --- models ------------------------------------------------------------------

rate_limited_model_cools_down() {
  new_repo '{"coder":{"models":["m/limited","m/good"]},"tiers":{"normal":{"race":1}}}'
  task a 'test -f a.txt' a.txt
  task b 'test -f b.txt' b.txt
  local out
  out="$(FAKE_QUOTA_MODELS=m/limited FAKE_CODER_CMD='echo x > a.txt' run f "$PLAN/a.md")"
  eq "fell back" m/good "$(field .model "$out")"
  eq "limit not counted as an attempt" 1 "$(field .attempts "$out")"
  : >"$FAKE_STATE/calls"
  FAKE_QUOTA_MODELS=m/limited FAKE_CODER_CMD='echo x > b.txt' run f "$PLAN/b.md" >/dev/null
  eq "limited model skipped next time" "" "$(grep m/limited "$FAKE_STATE/calls")"
}

race_first_lane_to_pass_wins() {
  new_repo '{"coder":{"models":["m/slow","m/fast"],"autoOrder":false}}'
  task a 'test -f out.txt' out.txt
  local out
  out="$(FAKE_CODER_CMD='[ "$FAKE_MODEL" = m/slow ] && sleep 30; echo $FAKE_MODEL > out.txt' run f "$PLAN/a.md")"
  eq status pass "$(field .status "$out")"
  eq lanes 2 "$(field .lanes "$out")"
  eq winner m/fast "$(field .model "$out")"
  eq "merged content" m/fast "$(on_main out.txt)"
  eq "loser worktrees removed" "" "$(ls .freeloader/worktrees/f | grep -v _main)"
  eq "loser branches removed" "" "$(git branch --list 'freeloader/f/a--r*')"
}

tier_sets_lanes_and_models() {
  new_repo '{"coder":{"models":["m/a","m/b","m/c"]},"tiers":{"hard":{"race":1,"models":["m/strong"]}}}'
  task e 'test -f e.txt' e.txt 'tier: easy'
  task h 'test -f h.txt' h.txt 'tier: hard'
  local out
  out="$(FAKE_CODER_CMD='echo x > e.txt' run f "$PLAN/e.md")"
  eq "easy lanes" 1 "$(field .lanes "$out")"
  out="$(FAKE_CODER_CMD='echo x > h.txt' run f "$PLAN/h.md")"
  eq "hard model first" m/strong "$(field .model "$out")"
}

better_model_goes_first() {
  new_repo '{"coder":{"models":["m/bad","m/good"],"roundsPerModel":1},"tiers":{"normal":{"race":1}}}'
  task a 'grep -q ok a.txt' a.txt
  task b 'grep -q ok b.txt' b.txt
  FAKE_CODER_CMD='[ "$FAKE_MODEL" = m/good ] && echo ok > a.txt || echo no > a.txt' run f "$PLAN/a.md" >/dev/null
  : >"$FAKE_STATE/calls"
  FAKE_CODER_CMD='echo ok > b.txt' run f "$PLAN/b.md" >/dev/null
  eq "first coder call" "freeloader-coder m/good" "$(grep coder "$FAKE_STATE/calls" | head -1)"
}

# --- parallel tasks ----------------------------------------------------------

parallel_conflict_then_rerun() {
  new_repo
  task a 'grep -q red shared.txt' shared.txt 'tier: easy'
  task b 'grep -q blue shared.txt' shared.txt 'tier: easy'
  FAKE_CODER_CMD='sleep 2; echo red > shared.txt' run f "$PLAN/a.md" >"$TMP/a.json" &
  FAKE_CODER_CMD='sleep 6; echo blue > shared.txt' run f "$PLAN/b.md" >"$TMP/b.json" &
  wait
  eq "first" pass "$(jq -r .status "$TMP/a.json")"
  eq "second" conflict "$(jq -r .status "$TMP/b.json")"
  eq "feature branch left clean" "" "$(git -C "$MAIN_WT" status --short)"
  eq "rerun" pass "$(field .status "$(FAKE_CODER_CMD='echo "red blue" > shared.txt' run f "$PLAN/b.md")")"
}

parallel_pass_alone_fail_together() {
  new_repo
  task a 'test -f a.txt && test ! -f b.txt' a.txt 'tier: easy'
  task b 'test -f b.txt && test ! -f a.txt' b.txt 'tier: easy'
  FAKE_CODER_CMD='sleep 2; echo x > a.txt' run f "$PLAN/a.md" >"$TMP/a.json" &
  FAKE_CODER_CMD='sleep 6; echo x > b.txt' run f "$PLAN/b.md" >"$TMP/b.json" &
  wait
  eq "first" pass "$(jq -r .status "$TMP/a.json")"
  eq "second" integration_fail "$(jq -r .status "$TMP/b.json")"
  eq "second rolled back" "" "$(on_main b.txt)"
  eq "no lock left" "" "$(ls .freeloader/locks 2>/dev/null)"
}

# --- status and stats --------------------------------------------------------

status_tracks_progress() {
  new_repo
  task a 'test -f a.txt' a.txt 'tier: easy'
  task b 'test -f b.txt' b.txt 'tier: easy
depends:
  - a'
  eq "next before" '["a"]' "$("$S/status.sh" f | jq -c .next)"
  FAKE_CODER_CMD='echo x > a.txt' run f "$PLAN/a.md" >/dev/null
  local out
  out="$("$S/status.sh" f)"
  eq "next after" '["b"]' "$(field '.next | tostring' "$out")"
  eq request "Build the thing" "$(field .request "$out")"
  eq "listed" f "$("$S/status.sh" | jq -r '.features[0].feature')"
  FAKE_CODER_CMD='echo x > b.txt' run f "$PLAN/b.md" >/dev/null
  eq done true "$("$S/status.sh" f | jq -r .done)"
}

stats_count_attempts() {
  new_repo '{"coder":{"models":["m/one"]},"tiers":{"normal":{"race":1}}}'
  task a 'grep -q right out.txt' out.txt
  FAKE_CODER_CMD='if echo "$FAKE_PROMPT" | grep -q "This command failed"; then echo right > out.txt; else echo wrong > out.txt; fi' run f "$PLAN/a.md" >/dev/null
  local out
  out="$("$S/stats.sh" f 2>/dev/null)"
  eq attempts 2 "$(field '.models[0].attempts' "$out")"
  eq "pass rate" 50 "$(field '.models[0].passRate' "$out")"
  eq "tasks passed" 1 "$(field '.tasks.passedFree' "$out")"
}

t "plan: valid plan gives waves" plan_ok
t "plan: problems are reported" plan_problems
t "plan: dependency cycle" plan_cycle
t "task: passes and merges" task_passes
t "task: gate feedback reaches the coder" gate_feedback_reaches_coder
t "task: review feedback reaches the coder" review_feedback_reaches_coder
t "task: out-of-scope change fails" out_of_scope_fails
t "task: protected edits are discarded" protected_edits_are_discarded
t "task: verify-only after a manual fix" verify_only_after_failure
t "task: cached pass is not rerun" cached_pass_is_not_rerun
t "task: bad task file is an error" bad_task_file_is_an_error
t "models: rate-limited model cools down" rate_limited_model_cools_down
t "models: race, first lane to pass wins" race_first_lane_to_pass_wins
t "models: tier sets lanes and models" tier_sets_lanes_and_models
t "models: better model goes first" better_model_goes_first
t "parallel: conflict, then rerun" parallel_conflict_then_rerun
t "parallel: pass alone, fail together" parallel_pass_alone_fail_together
t "status: tracks progress" status_tracks_progress
t "stats: counts attempts" stats_count_attempts

echo
echo "$PASSED checks passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
