#!/usr/bin/env bash
# status.sh [<feature>]
#
# Without a feature: lists the features that have a plan in this repository.
# With one: joins the plan with each task's last result, so a build that was
# interrupted can carry on. "next" is every task that has not passed and whose
# dependencies all have.
#
# Prints one JSON line.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

FEATURE="${1:-}"
need git jq
load_repo

task_status() {
  jq -r '.status // "pending"' "$FL_DIR/runs/$1/$2/result.json" 2>/dev/null || echo pending
}

if [ -z "$FEATURE" ]; then
  LIST="[]"
  for d in "$FL_DIR"/plan/*/; do
    [ -d "$d" ] || continue
    f="$(basename "$d")"
    total=0
    passed=0
    for t in "$d"*.md; do
      [ -f "$t" ] || continue
      total=$((total + 1))
      [ "$(task_status "$f" "$(basename "$t" .md)")" = pass ] && passed=$((passed + 1))
    done
    LIST="$(jq -c --arg f "$f" --argjson total "$total" --argjson passed "$passed" \
      --arg request "$(head -c 300 "$d/REQUEST.txt" 2>/dev/null)" \
      '. + [{feature: $f, tasks: $total, passed: $passed, done: ($total > 0 and $total == $passed),
             request: $request}]' <<<"$LIST")"
  done
  jq -cn --argjson features "$LIST" '{status: "ok", features: $features}'
  exit 0
fi

valid_name "$FEATURE" || die "invalid feature name"
PLAN="$FL_DIR/plan/$FEATURE"
[ -d "$PLAN" ] || die "no plan for feature '$FEATURE'"

CHECK="$("$FL_ROOT/scripts/check-plan.sh" "$FEATURE" 2>/dev/null)"
jq -e '.tasks' >/dev/null 2>&1 <<<"$CHECK" || die "could not read the plan for '$FEATURE'"

RESULTS="{}"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  r="$FL_DIR/runs/$FEATURE/$id/result.json"
  if [ -f "$r" ]; then
    RESULTS="$(jq -c --arg id "$id" --slurpfile r "$r" \
      '. + {($id): ($r[0] | {status, stage, model, attempts, worktree, detail: (.detail // "")[0:300]})}' <<<"$RESULTS")"
  fi
done <<<"$(jq -r '.tasks[].id' <<<"$CHECK")"

jq -cn --arg feature "$FEATURE" --arg plan "$PLAN" --arg branch "$(feature_branch "$FEATURE")" \
  --arg request "$(cat "$PLAN/REQUEST.txt" 2>/dev/null)" \
  --argjson check "$CHECK" --argjson results "$RESULTS" '
  ($check.tasks | map(. + ($results[.id] // {status: "pending"}))) as $tasks
  | ($tasks | map(select(.status == "pass") | .id)) as $passed
  | {status: "ok", feature: $feature, branch: $branch, plan: $plan, request: $request,
     planProblems: $check.problems,
     waves: $check.waves,
     tasks: ($tasks | map({id, title, depends, status, stage, model, detail} | with_entries(select(.value != null)))),
     passed: ($passed | length),
     total: ($tasks | length),
     next: ($tasks | map(select(.status != "pass" and ((.depends - $passed) | length) == 0) | .id)),
     done: (($tasks | length) > 0 and ($passed | length) == ($tasks | length))}'
