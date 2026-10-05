#!/usr/bin/env bash
# doctor.sh [--ping]
#
# Preflight for the freeloader workflow. Checks the tools, the opencode login, and that
# every configured model is on offer. --ping also sends one tiny request per model;
# it is off by default because free tiers have small quotas.
#
# Prints a human-readable report on stderr and one JSON line on stdout.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

PING=0
[ "${1:-}" = "--ping" ] && PING=1

PROBLEMS=""
WARNINGS=""
problem() { PROBLEMS="$PROBLEMS$1
"; echo "FAIL  $1" >&2; }
warn() { WARNINGS="$WARNINGS$1
"; echo "WARN  $1" >&2; }
ok() { echo "ok    $1" >&2; }

for c in git jq opencode; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c found"; else problem "$c is not installed"; fi
done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
  || command -v perl >/dev/null 2>&1 || problem "need one of: timeout, gtimeout, perl"

finish() {
  jq -cn --arg p "$PROBLEMS" --arg w "$WARNINGS" '
    ($p | split("\n") | map(select(. != ""))) as $p |
    {status: (if ($p | length) == 0 then "ok" else "fail" end), problems: $p,
     warnings: ($w | split("\n") | map(select(. != "")))}'
  [ -z "$PROBLEMS" ]
  exit $?
}
[ -z "$PROBLEMS" ] || finish

if git rev-parse --git-dir >/dev/null 2>&1; then
  load_repo
  ok "git repository: $REPO"
  git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || problem "repository has no commits yet; make one first"
  [ -f "$REPO/freeloader.config.json" ] && ok "using project freeloader.config.json"
  [ "$(cfg '.worktree.setup | length')" -gt 0 ] \
    || warn "worktree.setup is empty; if tests need installed dependencies (npm ci, a venv), add the command to freeloader.config.json"
else
  problem "not inside a git repository"
  # shellcheck disable=SC2034  # read by cfg() in lib.sh
  CFG="$(cat "$FL_ROOT/freeloader.config.default.json")"
fi

if [ "$(opencode auth list 2>/dev/null | grep -c .)" -gt 0 ]; then
  ok "opencode has stored credentials"
else
  warn "opencode auth list is empty; free models may still work, paid ones will not"
fi

AVAILABLE="$(opencode models 2>/dev/null)"
[ -n "$AVAILABLE" ] || problem "opencode models returned nothing; is opencode set up?"
FREE="$(grep -- '-free$' <<<"$AVAILABLE" | tr '\n' ' ')"

check_models() {
  local role=$1 model usable=0 left
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    if ! grep -qxF "$model" <<<"$AVAILABLE"; then
      warn "$role model not on offer: $model"
      continue
    fi
    if [ "$PING" -eq 1 ]; then
      build_agents_json
      run_opencode freeloader-reviewer "$model" 60 "$TMP/ping.jsonl" "Reply with the single word OK."
      if [ "$OC_STATUS" != ok ]; then
        warn "$role model $model did not answer: $OC_STATUS"
        continue
      fi
    fi
    if left="$(cooldown_left "$model")"; then
      warn "$role model $model is rate-limited; skipped for another $((left / 60 + 1)) min"
    else
      ok "$role model: $model"
    fi
    usable=$((usable + 1))
  done <<<"$(cfg "$2")"
  [ "$usable" -gt 0 ] || problem "no usable $role model. Free models currently on offer: $FREE"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 2
check_models coder '.coder.models[]'
check_models reviewer '.reviewer.models[]'
for tier in easy normal hard; do
  [ "$(cfg ".tiers.$tier.models // [] | length")" -eq 0 ] || check_models "$tier-tier coder" ".tiers.$tier.models[]"
done

finish
