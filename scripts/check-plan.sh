#!/usr/bin/env bash
# check-plan.sh <feature>
#
# Validates the task files in .swarm/plan/<feature>/ before any model is run:
# ids, acceptance commands, dependencies, protected files, and that no two tasks
# that could run at the same time are allowed to edit the same file.
#
# Prints one JSON line: status, problems, and the tasks grouped into waves. Every
# task in a wave can run in parallel once the earlier waves have passed.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: check-plan.sh <feature>"
FEATURE=$1

need git jq
valid_name "$FEATURE" || die "feature name may only contain letters, digits, '.', '_' and '-'"
load_repo

PLAN="$SWARM_DIR/plan/$FEATURE"
MAIN_WT="$(feature_worktree "$FEATURE")"
[ -d "$PLAN" ] || die "no plan directory: $PLAN"

PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS$1
"; }
to_json_list() { jq -Rsc 'split("\n") | map(select(. != ""))'; }
has_glob() { case "$1" in *[\*\?\[]*) return 0 ;; esac; return 1; }

# overlaps <pattern> <pattern>: could both match the same path?
overlaps() {
  [ "$1" = "$2" ] && return 0
  matches_any "$1" "$2" && return 0
  matches_any "$2" "$1" && return 0
  return 1
}

TASKS="[]"
N=0
for f in "$PLAN"/*.md; do
  [ -f "$f" ] || continue
  N=$((N + 1))
  name="$(basename "$f" .md)"
  id="$(task_field "$f" id)"
  accept="$(task_field "$f" accept)"
  files="$(task_list "$f" files)"
  protect="$(task_list "$f" protect)"

  if ! valid_name "$id"; then
    problem "$name.md: missing or invalid 'id'"
    continue
  fi
  [ "$id" = "$name" ] || problem "$name.md: id '$id' must match the file name"
  [ "$id" != "main" ] && [ "$id" != "_main" ] || problem "$name.md: id '$id' is reserved"
  [ -n "$accept" ] || problem "$id: missing 'accept' command"
  tier="$(task_field "$f" tier)"
  case "${tier:-normal}" in
    easy|normal|hard) ;;
    *) problem "$id: tier must be easy, normal or hard, not '$tier'" ;;
  esac
  [ -n "$files" ] || problem "$id: missing 'files'; list what the coder may change"
  [ -n "$(task_body "$f" | tr -d '[:space:]')" ] || problem "$id: the task has no description"

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    matches_any "$p" "$files" && problem "$id: '$p' is both protected and in 'files'"
    if ! has_glob "$p" && [ -d "$MAIN_WT" ] && [ ! -e "$MAIN_WT/$p" ]; then
      problem "$id: protected path '$p' does not exist in the feature worktree; write it there first"
    fi
  done <<<"$protect"

  TASKS="$(jq -c --arg id "$id" --arg title "$(task_title "$f")" --arg tier "${tier:-normal}" \
    --argjson files "$(printf '%s\n' "$files" | to_json_list)" \
    --argjson depends "$(task_list "$f" depends | to_json_list)" \
    '. + [{id: $id, title: $title, tier: $tier, files: $files, depends: $depends}]' <<<"$TASKS")"
done
[ "$N" -gt 0 ] || problem "no task files in $PLAN"

# Pairs of tasks whose 'files' could touch the same path. jq decides below which
# pairs matter, since a pair ordered by a dependency never runs at the same time.
PAIRS="[]"
count="$(jq 'length' <<<"$TASKS")"
i=0
while [ "$i" -lt "$count" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$count" ]; do
    hit=""
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        if overlaps "$a" "$b"; then hit="$a"; break 2; fi
      done <<<"$(jq -r ".[$j].files[]" <<<"$TASKS")"
    done <<<"$(jq -r ".[$i].files[]" <<<"$TASKS")"
    [ -z "$hit" ] || PAIRS="$(jq -c --argjson i "$i" --argjson j "$j" --arg f "$hit" \
      --argjson t "$TASKS" '. + [{a: $t[$i].id, b: $t[$j].id, file: $f}]' <<<"$PAIRS")"
    j=$((j + 1))
  done
  i=$((i + 1))
done

jq -cn --argjson tasks "$TASKS" --argjson pairs "$PAIRS" --arg problems "$PROBLEMS" '
  ($tasks | map(.id)) as $ids
  | ($tasks | group_by(.id) | map(select(length > 1) | "duplicate task id: \(.[0].id)")) as $dupes
  | ($tasks | map(. as $t | .depends[] | select(. as $d | $ids | index($d) | not)
      | "\($t.id): depends on unknown task \(.)")) as $missing
  | ($tasks | map(.depends |= map(select(. as $d | $ids | index($d))))) as $known
  | def waves($done; $rest):
      ($rest | map(select((.depends - $done) | length == 0))) as $ready
      | if ($rest | length) == 0 then []
        elif ($ready | length) == 0 then [{cycle: ($rest | map(.id))}]
        else [($ready | map(.id))] + waves($done + ($ready | map(.id)); $rest - $ready)
        end;
    waves([]; $known) as $w
  | ($w | map(select(type == "object") | "dependency cycle among: \(.cycle | join(", "))")) as $cycles
  | ($known | map({key: .id, value: .depends}) | from_entries) as $deps
  | def ancestors($id): ($deps[$id] // []) as $d | ($d + ($d | map(ancestors(.)) | add // [])) | unique;
    (if ($cycles | length) > 0 then []
     else $pairs | map(. as $p | select((ancestors($p.a) | index($p.b) | not) and (ancestors($p.b) | index($p.a) | not))
       | "\(.a) and \(.b) can run in parallel but both may edit \(.file); add a dependency or split the file")
     end) as $clashes
  | (($problems | split("\n") | map(select(. != ""))) + $dupes + $missing + $cycles + $clashes) as $all
  | {status: (if ($all | length) == 0 then "ok" else "fail" end),
     problems: $all,
     waves: ($w | map(select(type == "array"))),
     tasks: ($tasks | map({id, title, tier, depends}))}'
