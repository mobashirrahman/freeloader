#!/usr/bin/env bash
# Shared helpers for the freeloader scripts. Source this; do not run it.
# Written for bash 3.2 so it works with the stock macOS shell.

FL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every script prints exactly one JSON line on stdout; errors follow the same rule.
die() {
  echo "freeloader: $1" >&2
  jq -cn --arg e "$1" '{status:"error",error:$e}' 2>/dev/null || echo '{"status":"error"}'
  exit 2
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

valid_name() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Sets REPO (the main checkout, even when called from a worktree), FL_DIR, CFG.
load_repo() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "not inside a git repository"
  REPO="$(dirname "$common")"
  FL_DIR="$REPO/.freeloader"
  mkdir -p "$FL_DIR"
  # Keep .freeloader out of the user's status without touching their tracked .gitignore.
  grep -qxF '.freeloader/' "$common/info/exclude" 2>/dev/null || {
    mkdir -p "$common/info"
    echo '.freeloader/' >> "$common/info/exclude"
  }
  # Commits and merges on freeloader branches must not fail for lack of an identity.
  if ! git -C "$REPO" config user.email >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME=freeloader GIT_AUTHOR_EMAIL=freeloader@localhost
    export GIT_COMMITTER_NAME=freeloader GIT_COMMITTER_EMAIL=freeloader@localhost
  fi
  # Defaults, then the user's own settings, then the repository's.
  CFG="$(cat "$FL_ROOT/freeloader.config.default.json")"
  local extra
  for extra in "${XDG_CONFIG_HOME:-$HOME/.config}/freeloader/config.json" "$REPO/freeloader.config.json"; do
    [ -f "$extra" ] || continue
    CFG="$(jq -s '.[0] * .[1]' <(printf '%s' "$CFG") "$extra")" || die "$extra is not valid JSON"
  done
}

cfg() { jq -r "$1" <<<"$CFG"; }

with_timeout() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
  fi
}

is_timeout_rc() { [ "$1" -eq 124 ] || [ "$1" -eq 142 ]; }

# The coder and the reviewer both run on opencode's stock "build" agent. What sets
# them apart is the permission config passed for that one run, and the role
# instructions put at the top of the prompt. Nothing is written to the user's own
# opencode config. (Custom agents are avoided: opencode's free tier is reported to
# refuse them.)
build_role_configs() {
  CODER_CONFIG="$(jq -cn --argjson deny "$(cfg '.coder.shellDeny')" --argjson web "$(cfg '.coder.web')" '
    {permission: ({
      "*": "deny", read: "allow", grep: "allow", glob: "allow", edit: "allow",
      external_directory: "deny",
      bash: ({"*": "allow"} + ($deny | map({(.): "deny"}) | add // {}))
    } + (if $web then {webfetch: "allow"} else {} end))}')"
  REVIEWER_CONFIG="$(jq -cn --argjson web "$(cfg '.reviewer.web')" '
    {permission: ({
      "*": "deny", read: "allow", grep: "allow", glob: "allow",
      external_directory: "deny"
    } + (if $web then {webfetch: "allow"} else {} end))}')"
}

# run_opencode <coder|reviewer> <model> <timeout-sec> <log-file> <prompt>
# Runs in the current directory. Sets OC_STATUS to ok | quota | refused | timeout |
# error, OC_TEXT to the model's text output, OC_ERROR to the provider's message,
# and OC_EGRESS to the label of the exit used, if any.
# "refused" is the provider declining to serve this request at all, which is how
# opencode's free tier answers requests it does not accept.
run_opencode() {
  local role=$1 model=$2 secs=$3 log=$4 prompt=$5 rc etype config tries=0
  if [ "$role" = coder ]; then config="$CODER_CONFIG"; else config="$REVIEWER_CONFIG"; fi
  prompt="$(cat "$FL_ROOT/opencode/$role.md")

$prompt"
  OC_EGRESS=""
  while :; do
    rc=0
    if [ "${EGRESS_ON:-0}" -eq 1 ]; then
      if ! egress_start; then
        OC_STATUS=error
        OC_TEXT=""
        OC_ERROR="no egress exit is available, and egress is set to fail closed"
        return 0
      fi
      OC_EGRESS="$EG_LABEL"
      HTTPS_PROXY="http://127.0.0.1:$EG_PORT" HTTP_PROXY="http://127.0.0.1:$EG_PORT" \
      https_proxy="http://127.0.0.1:$EG_PORT" http_proxy="http://127.0.0.1:$EG_PORT" \
      NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" \
        opencode_exec "$role" "$model" "$secs" "$log" "$config" "$prompt" || rc=$?
      egress_stop
    else
      opencode_exec "$role" "$model" "$secs" "$log" "$config" "$prompt" || rc=$?
    fi
    etype="$(jq -rR 'fromjson? | select(.type=="error") | .error.type' "$log" 2>/dev/null | head -1)"
    # A transport error with nothing getting through the exit means the exit is
    # dead, not the model. Retire it and try another; never fall back to direct.
    if [ "${EGRESS_ON:-0}" -eq 1 ] && [ "$etype" = "provider.transport" ] \
      && ! grep -q '^ok' "$EG_LOG" 2>/dev/null && [ "$tries" -lt 2 ]; then
      egress_mark_dead "$EG_ID"
      tries=$((tries + 1))
      continue
    fi
    break
  done
  # shellcheck disable=SC2034  # read by the callers
  OC_TEXT="$(jq -rR 'fromjson? | select(.type=="text") | .part.text' "$log" 2>/dev/null || true)"
  # shellcheck disable=SC2034  # read by the callers
  OC_ERROR="$(jq -rR 'fromjson? | select(.type=="error") | .error.message' "$log" 2>/dev/null | head -1 | cut -c 1-200)"
  if is_timeout_rc "$rc"; then
    OC_STATUS=timeout
  elif [ "$etype" = "provider.quota" ]; then
    OC_STATUS=quota
  elif [ "$etype" = "provider.auth" ]; then
    OC_STATUS=refused
  elif [ -n "$etype" ] || [ "$rc" -ne 0 ]; then
    OC_STATUS=error
  else
    OC_STATUS=ok
  fi
  case "$OC_STATUS" in
    quota|refused) mark_cooldown "$model" ;;
    ok) clear_cooldown "$model" ;;
  esac
  # A rate limit rotates the egress exit (when enabled) so the next attempt
  # leaves through a fresh proxy. Key-based quotas will not lift, but
  # IP-based throttling might; the model cooldown still applies either way.
  # Note: `.egress.rotateOnQuota // true` would be wrong here, since jq's //
  # treats an explicit false like a missing key.
  if [ "$OC_STATUS" = quota ] && [ "${EGRESS_ON:-0}" -eq 1 ] \
    && [ "$(cfg '.egress.rotateOnQuota | if . == null then true else . end')" = true ]; then
    egress_rotate "${EG_ID:-}"
  fi
}

opencode_exec() {
  # An empty config dir keeps the user's global MCP servers and plugins out of the run.
  FREELOADER_ROLE="$1" \
  OPENCODE_CONFIG_DIR="$FL_ROOT/opencode/config" \
  OPENCODE_CONFIG_CONTENT="$5" \
    with_timeout "$3" opencode run --standalone --agent build -m "$2" \
      --auto --format json "$6" >"$4" 2>&1 </dev/null
}

# --- egress ------------------------------------------------------------------
# Optional: send every model call through one of the user's own proxies.
# Pool semantics mirror pi-swarm (vendor/pi-swarm/egress.ts): random sticky
# exit, fail-closed country filter, TTL blacklist, plus rotation to a fresh
# exit on provider rate limits (egress.rotateOnQuota). Supported upstreams are
# http://, https://, socks://, socks5:// and socks5h:// in CC=url, url#CC,
# url#country=CC and url?country=CC forms.
#
# Proxy URLs carry credentials, so they are never logged or put in the agent's
# environment. Each call gets a forwarder on 127.0.0.1 (egress-forward.js) that
# holds them; everything else sees only a label such as "US-3f2a".

# Sets EGRESS_ON and EGRESS_LIST (one "id<TAB>country<TAB>url" per line).
# Parsing lives in scripts/egress-parse.js, derived from the vendored
# pi-swarm pool (vendor/pi-swarm/egress.ts), so entry forms, JSON files,
# and PI_SWARM_* env names stay in sync. Ids remain cksum(url) so existing
# .freeloader/state/egress-current files keep working.
load_egress() {
  EGRESS_ON=0
  EGRESS_LIST=""
  [ "$(cfg '.egress.mode')" = on ] || return 0
  need node
  local parsed country url id cfg_file cfg_countries err_file
  cfg_file="$(cfg '.egress.proxiesFile // ""')"
  cfg_countries="$(cfg '.egress.countries // [] | map(ascii_upcase) | join(",")')"
  err_file="${FL_DIR:-/tmp}/egress-parse.err"
  # Re-export shell vars (tests set them without export) for the node parser.
  parsed="$(FREELOADER_PROXIES="${FREELOADER_PROXIES:-}" PI_SWARM_PROXIES="${PI_SWARM_PROXIES:-}" FREELOADER_PROXIES_FILE="${FREELOADER_PROXIES_FILE:-}" PI_SWARM_PROXIES_FILE="${PI_SWARM_PROXIES_FILE:-}" PI_SWARM_EGRESS_COUNTRIES="${PI_SWARM_EGRESS_COUNTRIES:-}" FREELOADER_EGRESS_COUNTRIES="${FREELOADER_EGRESS_COUNTRIES:-}" node "$FL_ROOT/scripts/egress-parse.js" --proxies-file "$cfg_file" --countries "$cfg_countries" 2>"$err_file")" || {
    cat "$err_file" >&2 2>/dev/null || true
    die "egress: cannot read proxies file ${FREELOADER_PROXIES_FILE:-${PI_SWARM_PROXIES_FILE:-$cfg_file}}"
  }
  # The list is now held in this shell only. Drop it from the environment so that
  # no child process, least of all an agent with a shell, inherits it.
  unset FREELOADER_PROXIES FREELOADER_PROXIES_FILE PI_SWARM_PROXIES PI_SWARM_PROXIES_FILE PI_SWARM_EGRESS_COUNTRIES FREELOADER_EGRESS_COUNTRIES
  local seen_ids=" "
  while IFS='	' read -r country url; do
    [ -n "$url" ] || continue
    id="$(printf '%s' "$url" | cksum | cut -d' ' -f1)"
    # Same upstream listed twice (e.g. with/without trailing slash collapsed
    # upstream) keeps the first country so the label stays stable.
    case "$seen_ids" in *" $id "*) continue ;; esac
    seen_ids="$seen_ids$id "
    EGRESS_LIST="$EGRESS_LIST$id	$country	$url
"
  done <<<"$parsed"
  [ -n "$EGRESS_LIST" ] || die "egress is on but no usable proxy was found (check egress.proxiesFile and egress.countries)"
  EGRESS_ON=1
}

egress_label() { # <id> <country>
  printf '%s-%04x' "${2:-XX}" "$(($1 % 65536))"
}

egress_is_dead() {
  local until
  until="$(cat "$FL_DIR/state/egress-dead/$1" 2>/dev/null)"
  case "$until" in ""|*[!0-9]*) return 1 ;; esac
  [ "$(date +%s)" -lt "$until" ]
}

egress_mark_dead() {
  mkdir -p "$FL_DIR/state/egress-dead"
  echo $(($(date +%s) + $(cfg '.egress.retrySec'))) >"$FL_DIR/state/egress-dead/$1"
}

# Picks the exit to use: the current one if it is still listed and alive,
# otherwise a random live one, which then becomes current. Sets EG_ID,
# EG_COUNTRY, EG_URL; fails when no exit is alive.
egress_pick() {
  local current alive="" id country url n pick
  current="$(cat "$FL_DIR/state/egress-current" 2>/dev/null)"
  while IFS='	' read -r id country url; do
    [ -n "$id" ] || continue
    egress_is_dead "$id" && continue
    if [ "$id" = "$current" ]; then
      EG_ID=$id EG_COUNTRY=$country EG_URL=$url
      return 0
    fi
    alive="$alive$id	$country	$url
"
  done <<<"$EGRESS_LIST"
  n="$(printf '%s' "$alive" | grep -c .)"
  [ "$n" -gt 0 ] || return 1
  pick=$(($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % n + 1))
  IFS='	' read -r EG_ID EG_COUNTRY EG_URL <<<"$(printf '%s' "$alive" | sed -n "${pick}p")"
  mkdir -p "$FL_DIR/state"
  echo "$EG_ID" >"$FL_DIR/state/egress-current"
}

# Rotates the sticky exit after a rate limit: records a different live exit
# than $1 (or the recorded current), so the next call leaves through a fresh
# proxy. Keeps the current one when no alternative is alive. Never fails.
egress_rotate() {
  local old="${1:-$(cat "$FL_DIR/state/egress-current" 2>/dev/null)}"
  local alive="" id country url n pick
  while IFS='	' read -r id country url; do
    [ -n "$id" ] || continue
    [ "$id" != "$old" ] || continue
    egress_is_dead "$id" && continue
    alive="$alive$id	$country	$url
"
  done <<<"$EGRESS_LIST"
  n="$(printf '%s' "$alive" | grep -c .)"
  [ "$n" -gt 0 ] || return 0
  pick=$(($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % n + 1))
  id="$(printf '%s' "$alive" | sed -n "${pick}p" | cut -f1)"
  mkdir -p "$FL_DIR/state"
  echo "$id" >"$FL_DIR/state/egress-current"
}

# Starts a forwarder for the picked exit. Sets EG_PORT, EG_PID, EG_LOG, EG_LABEL.
egress_start() {
  local dir waited=0
  egress_pick || return 1
  EG_LABEL="$(egress_label "$EG_ID" "$EG_COUNTRY")"
  dir="$(mktemp -d)"
  EG_LOG="$dir/log"
  FREELOADER_UPSTREAM_PROXY="$EG_URL" node "$FL_ROOT/scripts/egress-forward.js" >"$dir/port" 2>"$EG_LOG" &
  EG_PID=$!
  EG_URL=""
  until [ -s "$dir/port" ]; do
    kill -0 "$EG_PID" 2>/dev/null || return 1
    [ "$waited" -lt 50 ] || { kill "$EG_PID" 2>/dev/null; return 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  EG_PORT="$(cat "$dir/port")"
}

egress_stop() {
  [ -n "${EG_PID:-}" ] || return 0
  kill "$EG_PID" 2>/dev/null
  wait "$EG_PID" 2>/dev/null
  EG_PID=""
}

# --- quota cooldown ----------------------------------------------------------
# A model that answers with a rate limit is skipped until its cooldown expires,
# so later tasks do not each waste an attempt rediscovering the limit.

cooldown_file() {
  echo "$FL_DIR/state/cooldown/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Prints the seconds of cooldown left for a model; fails if it is not cooling.
cooldown_left() {
  local until now
  [ -n "${FL_DIR:-}" ] || return 1
  until="$(cat "$(cooldown_file "$1")" 2>/dev/null)"
  case "$until" in ""|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ] || return 1
  echo $((until - now))
}

mark_cooldown() {
  [ -n "${FL_DIR:-}" ] || return 0
  mkdir -p "$FL_DIR/state/cooldown"
  echo $(($(date +%s) + $(cfg '.quota.cooldownSec'))) >"$(cooldown_file "$1")"
}

clear_cooldown() {
  [ -n "${FL_DIR:-}" ] || return 0
  rm -f "$(cooldown_file "$1")"
}

# ready_models <newline-separated models>: the ones that are not cooling down.
ready_models() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cooldown_left "$m" >/dev/null || printf '%s\n' "$m"
  done <<<"$1"
}

# usable_models <newline-separated models>: like ready_models, but if every model
# is cooling it returns them all, since a cooldown is only a guess at the real
# limit and a coder is needed either way.
usable_models() {
  local out
  out="$(ready_models "$1")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '%s\n' "$1"; fi
}

# --- ledger ------------------------------------------------------------------
# One JSON line per coder attempt and per finished task, in .freeloader/ledger.jsonl.

ledger() { printf '%s\n' "$1" >>"$FL_DIR/ledger.jsonl"; }

# ordered_models <newline-separated models>: best recorded pass rate first. The
# rate is smoothed, so an untried model sits at 50% and keeps its configured place
# among equals. Rate limits, refusals and outages are not counted against a model.
ordered_models() {
  if [ "$(cfg '.coder.autoOrder')" != true ] || [ ! -s "$FL_DIR/ledger.jsonl" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  jq -rn --arg list "$1" --slurpfile ledger "$FL_DIR/ledger.jsonl" '
    ($ledger
      | map(select(.kind == "attempt" and (.outcome | IN("quota", "refused", "error") | not)))
      | group_by(.model)
      | map({key: .[0].model,
             value: (((map(select(.outcome == "pass")) | length) + 1) / (length + 2))})
      | from_entries) as $rate
    | $list | split("\n") | map(select(. != "")) | to_entries
    | sort_by([-($rate[.value] // 0.5), .key]) | .[].value' 2>/dev/null \
    || printf '%s\n' "$1"
}

# --- task files --------------------------------------------------------------

task_frontmatter() { awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f' "$1"; }
task_body() { awk 'NR==1 && $0=="---" {f=1; next} f==1 && $0=="---" {f=2; next} f==2' "$1"; }
unquote() { sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/"; }

# task_field <file> <key>: a single-line frontmatter value.
task_field() {
  task_frontmatter "$1" \
    | awk -v k="$2" 'index($0, k ":") == 1 { sub("^" k ":[ \t]*", ""); print; exit }' | unquote
}

# task_list <file> <key>: a frontmatter list, one item per line.
task_list() {
  task_frontmatter "$1" | awk -v k="$2" '
    $0 ~ "^" k ":" { f = 1; next }
    f && /^[ \t]+-[ \t]+/ { sub(/^[ \t]+-[ \t]+/, ""); print; next }
    f && /^[^ \t]/ { f = 0 }' | unquote
}

task_title() { task_body "$1" | awk '/^#+ / { sub(/^#+ /, ""); print; exit }'; }

# matches_any <string> <newline-separated glob patterns>; "dir/" matches everything under it.
matches_any() {
  local s=$1 pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in */) pat="$pat*" ;; esac
    # shellcheck disable=SC2254
    case "$s" in $pat) return 0 ;; esac
  done <<<"$2"
  return 1
}

# Pull the outermost {...} out of free-form model text.
extract_json() {
  awk 'BEGIN { RS = "\001" } {
    s = index($0, "{"); if (!s) exit 1
    e = 0
    for (i = length($0); i > 0; i--) if (substr($0, i, 1) == "}") { e = i; break }
    if (e < s) exit 1
    print substr($0, s, e - s + 1)
  }'
}

git_commit() {
  # Internal branches, so the user's commit hooks are skipped.
  git -C "$1" commit -q --no-verify -m "$2"
}

# Directory locks under .freeloader/locks, with the holder's pid so a dead holder can be evicted.
acquire_lock() {
  local lock="$FL_DIR/locks/$1" waited=0 pid
  mkdir -p "$FL_DIR/locks"
  until mkdir "$lock" 2>/dev/null; do
    pid="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    [ "$waited" -lt 900 ] || die "timed out waiting for lock $lock"
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ >"$lock/pid"
  HELD_LOCK="$lock"
}

release_lock() {
  [ -n "${HELD_LOCK:-}" ] && rm -rf "$HELD_LOCK"
  HELD_LOCK=""
}
trap release_lock EXIT

feature_branch() { echo "freeloader/$1/main"; }
feature_worktree() { echo "$FL_DIR/worktrees/$1/_main"; }

# Creates the integration branch and worktree for a feature if they do not exist.
ensure_feature() {
  local feature=$1 branch wt
  branch="$(feature_branch "$feature")"
  wt="$(feature_worktree "$feature")"
  [ -d "$wt" ] && return 0
  acquire_lock _git
  if [ ! -d "$wt" ]; then
    git -C "$REPO" worktree prune
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$REPO" worktree add -q "$wt" "$branch" >&2 || die "cannot create worktree for $branch"
    else
      git -C "$REPO" worktree add -q -b "$branch" "$wt" HEAD >&2 || die "cannot create branch $branch"
    fi
    run_setup "$wt"
  fi
  release_lock
}

run_setup() {
  local wt=$1 n i cmd
  n="$(cfg '.worktree.setup | length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    cmd="$(cfg ".worktree.setup[$i]")"
    (cd "$wt" && bash -c "$cmd") >>"$FL_DIR/setup.log" 2>&1 \
      || die "worktree setup command failed: $cmd (see .freeloader/setup.log)"
    i=$((i + 1))
  done
}
