#!/usr/bin/env bash
# stats.sh [<feature>]
#
# Summarises the run ledger (.swarm/ledger.jsonl): how each model has performed
# and how tasks ended, for one feature or for everything recorded in this repo.
#
# Prints a table on stderr and one JSON line on stdout.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

FEATURE="${1:-}"
need git jq
[ -z "$FEATURE" ] || valid_name "$FEATURE" || die "invalid feature name"
load_repo

LEDGER="$SWARM_DIR/ledger.jsonl"
[ -s "$LEDGER" ] || die "nothing recorded yet; run a task first"

OUT="$(jq -cn --arg feature "$FEATURE" --slurpfile ledger "$LEDGER" '
  def pct: if . == null then null else (. * 100 | round) end;
  ($ledger | map(select($feature == "" or .feature == $feature))) as $rows
  | ($rows | map(select(.kind == "attempt"))) as $attempts
  | ($rows | map(select(.kind == "task"))) as $runs
  # A task may be run several times; its last run is what counts.
  | ($runs | group_by([.feature, .id]) | map(last)) as $tasks
  | {feature: (if $feature == "" then null else $feature end),
     models: ($attempts | group_by(.model) | map(
        (map(select(.outcome != "quota" and .outcome != "error"))) as $real
        | {model: .[0].model,
           attempts: ($real | length),
           passes: ($real | map(select(.outcome == "pass")) | length),
           passRate: (if ($real | length) == 0 then null
                      else (($real | map(select(.outcome == "pass")) | length) / ($real | length)) end | pct),
           failedAt: ($real | map(select(.outcome != "pass") | .outcome) | group_by(.)
                      | map({key: .[0], value: length}) | from_entries),
           rateLimited: (map(select(.outcome == "quota")) | length),
           avgSeconds: (if ($real | length) == 0 then null
                        else ($real | map(.seconds) | add / length | round) end)})
        | sort_by(-(.passRate // -1), -.attempts)),
     tasks: {
       total: ($tasks | length),
       passedFree: ($tasks | map(select(.status == "pass" and .model != "external")) | length),
       passedEscalated: ($tasks | map(select(.status == "pass" and .model == "external")) | length),
       notPassed: ($tasks | map(select(.status != "pass")) | length),
       avgSeconds: (if ($tasks | length) == 0 then null else ($tasks | map(.seconds) | add / length | round) end)},
     byTier: ($tasks | group_by(.tier) | map({key: .[0].tier, value: {
        total: length,
        passedFree: (map(select(.status == "pass" and .model != "external")) | length)}}) | from_entries)}')" \
  || die "could not read the ledger"

{
  printf '%-44s %8s %7s %6s %8s %7s\n' MODEL ATTEMPTS PASSES RATE "429s" "AVG s"
  jq -r '.models[] | [.model, .attempts, .passes, (if .passRate == null then "-" else "\(.passRate)%" end),
    .rateLimited, (.avgSeconds // "-")] | @tsv' <<<"$OUT" \
    | while IFS="$(printf '\t')" read -r m a p r q t; do
        printf '%-44s %8s %7s %6s %8s %7s\n' "$m" "$a" "$p" "$r" "$q" "$t"
      done
  jq -r '.tasks | "\nTasks: \(.total) total, \(.passedFree) passed on free models, \(.passedEscalated) passed after escalation, \(.notPassed) not passed"' <<<"$OUT"
} >&2

printf '%s\n' "$OUT"
