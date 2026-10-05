#!/usr/bin/env bash
# Shared helpers for the swarm scripts. Source this; do not run it.
# Written for bash 3.2 so it works with the stock macOS shell.

SWARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every script prints exactly one JSON line on stdout; errors follow the same rule.
die() {
  echo "swarm: $1" >&2
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

# Sets REPO (the main checkout, even when called from a worktree), SWARM_DIR, CFG.
load_repo() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "not inside a git repository"
  REPO="$(dirname "$common")"
  SWARM_DIR="$REPO/.swarm"
  mkdir -p "$SWARM_DIR"
  # Keep .swarm out of the user's status without touching their tracked .gitignore.
  grep -qxF '.swarm/' "$common/info/exclude" 2>/dev/null || {
    mkdir -p "$common/info"
    echo '.swarm/' >> "$common/info/exclude"
  }
  # Commits and merges on swarm branches must not fail for lack of an identity.
  if ! git -C "$REPO" config user.email >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME=swarm GIT_AUTHOR_EMAIL=swarm@localhost
    export GIT_COMMITTER_NAME=swarm GIT_COMMITTER_EMAIL=swarm@localhost
  fi
  if [ -f "$REPO/swarm.config.json" ]; then
    CFG="$(jq -s '.[0] * .[1]' "$SWARM_ROOT/swarm.config.default.json" "$REPO/swarm.config.json")" \
      || die "swarm.config.json is not valid JSON"
  else
    CFG="$(cat "$SWARM_ROOT/swarm.config.default.json")"
  fi
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

# Agents are injected per run, so nothing is written to the user's opencode config.
build_agents_json() {
  AGENTS_JSON="$(jq -cn \
    --rawfile coder "$SWARM_ROOT/opencode/coder.md" \
    --rawfile reviewer "$SWARM_ROOT/opencode/reviewer.md" \
    --argjson deny "$(cfg '.coder.shellDeny')" '
    {agent: {
      "swarm-coder": {
        description: "Implements one swarm task",
        mode: "primary",
        prompt: $coder,
        permission: {
          "*": "deny", read: "allow", grep: "allow", glob: "allow", edit: "allow",
          external_directory: "deny",
          bash: ({"*": "allow"} + ($deny | map({(.): "deny"}) | add // {}))
        }
      },
      "swarm-reviewer": {
        description: "Reviews one swarm task diff",
        mode: "primary",
        prompt: $reviewer,
        permission: {
          "*": "deny", read: "allow", grep: "allow", glob: "allow",
          external_directory: "deny"
        }
      }
    }}')"
}

# run_opencode <agent> <model> <timeout-sec> <log-file> <prompt>
# Runs in the current directory. Sets OC_STATUS to ok | quota | timeout | error
# and OC_TEXT to the model's text output.
run_opencode() {
  local agent=$1 model=$2 secs=$3 log=$4 prompt=$5 rc=0 etype
  # An empty config dir keeps the user's global MCP servers and plugins out of the run.
  OPENCODE_CONFIG_DIR="$SWARM_ROOT/opencode/config" \
  OPENCODE_CONFIG_CONTENT="$AGENTS_JSON" \
    with_timeout "$secs" opencode run --standalone --agent "$agent" -m "$model" \
      --auto --format json "$prompt" >"$log" 2>&1 </dev/null || rc=$?
  OC_TEXT="$(jq -rR 'fromjson? | select(.type=="text") | .part.text' "$log" 2>/dev/null || true)"
  etype="$(jq -rR 'fromjson? | select(.type=="error") | .error.type' "$log" 2>/dev/null | head -1)"
  if is_timeout_rc "$rc"; then
    OC_STATUS=timeout
  elif [ "$etype" = "provider.quota" ]; then
    OC_STATUS=quota
  elif [ -n "$etype" ] || [ "$rc" -ne 0 ]; then
    OC_STATUS=error
  else
    OC_STATUS=ok
  fi
  case "$OC_STATUS" in
    quota) mark_cooldown "$model" ;;
    ok) clear_cooldown "$model" ;;
  esac
}

# --- quota cooldown ----------------------------------------------------------
# A model that answers with a rate limit is skipped until its cooldown expires,
# so later tasks do not each waste an attempt rediscovering the limit.

cooldown_file() {
  echo "$SWARM_DIR/state/cooldown/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Prints the seconds of cooldown left for a model; fails if it is not cooling.
cooldown_left() {
  local until now
  [ -n "${SWARM_DIR:-}" ] || return 1
  until="$(cat "$(cooldown_file "$1")" 2>/dev/null)"
  case "$until" in ""|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ] || return 1
  echo $((until - now))
}

mark_cooldown() {
  [ -n "${SWARM_DIR:-}" ] || return 0
  mkdir -p "$SWARM_DIR/state/cooldown"
  echo $(($(date +%s) + $(cfg '.quota.cooldownSec'))) >"$(cooldown_file "$1")"
}

clear_cooldown() {
  [ -n "${SWARM_DIR:-}" ] || return 0
  rm -f "$(cooldown_file "$1")"
}

# usable_models <newline-separated models>: drops the cooling ones. If every model
# is cooling, returns them all, since a cooldown is only a guess at the real limit.
usable_models() {
  local m out=""
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cooldown_left "$m" >/dev/null || out="$out$m
"
  done <<<"$1"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s\n' "$1"; fi
}

# --- ledger ------------------------------------------------------------------
# One JSON line per coder attempt and per finished task, in .swarm/ledger.jsonl.

ledger() { printf '%s\n' "$1" >>"$SWARM_DIR/ledger.jsonl"; }

# ordered_models <newline-separated models>: best recorded pass rate first. The
# rate is smoothed, so an untried model sits at 50% and keeps its configured place
# among equals. Rate limits and outages are not counted against a model.
ordered_models() {
  if [ "$(cfg '.coder.autoOrder')" != true ] || [ ! -s "$SWARM_DIR/ledger.jsonl" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  jq -rn --arg list "$1" --slurpfile ledger "$SWARM_DIR/ledger.jsonl" '
    ($ledger
      | map(select(.kind == "attempt" and .outcome != "quota" and .outcome != "error"))
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

# Directory locks under .swarm/locks, with the holder's pid so a dead holder can be evicted.
acquire_lock() {
  local lock="$SWARM_DIR/locks/$1" waited=0 pid
  mkdir -p "$SWARM_DIR/locks"
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

feature_branch() { echo "swarm/$1/main"; }
feature_worktree() { echo "$SWARM_DIR/worktrees/$1/_main"; }

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
    (cd "$wt" && bash -c "$cmd") >>"$SWARM_DIR/setup.log" 2>&1 \
      || die "worktree setup command failed: $cmd (see .swarm/setup.log)"
    i=$((i + 1))
  done
}
