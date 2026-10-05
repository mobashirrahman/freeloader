#!/usr/bin/env bash
# feature.sh <action> <feature> [argument]
#
#   start <feature> [request]  create the integration branch and worktree and the
#                              plan directory, and record what was asked for
#   commit-tests <feature>     commit what the architect wrote into the feature
#                              worktree, so every task starts with the acceptance
#                              tests already in place
#   diff <feature>             write the feature's full diff to a file for review
#   pr <feature> [base]        push the feature branch and open a pull request
#                              against base (default: the branch checked out now)
#   cleanup <feature>          remove the feature's worktrees and task branches
#                              (keeps swarm/<feature>/main)
#
# Prints exactly one JSON line.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] && [ $# -le 3 ] || die "usage: feature.sh <start|commit-tests|diff|pr|cleanup> <feature> [argument]"
ACTION=$1
FEATURE=$2
ARG="${3:-}"

need git jq
valid_name "$FEATURE" || die "feature name may only contain letters, digits, '.', '_' and '-'"
load_repo

BRANCH="$(feature_branch "$FEATURE")"
MAIN_WT="$(feature_worktree "$FEATURE")"
PLAN="$SWARM_DIR/plan/$FEATURE"

case "$ACTION" in
  start)
    ensure_feature "$FEATURE"
    mkdir -p "$PLAN"
    [ -z "$ARG" ] || printf '%s\n' "$ARG" >"$PLAN/REQUEST.txt"
    jq -cn --arg feature "$FEATURE" --arg branch "$BRANCH" --arg worktree "$MAIN_WT" --arg plan "$PLAN" \
      '{status: "ok", feature: $feature, branch: $branch, worktree: $worktree, plan: $plan}'
    ;;
  commit-tests)
    [ -d "$MAIN_WT" ] || die "feature not started: $FEATURE"
    acquire_lock "$FEATURE"
    git -C "$MAIN_WT" add -A
    FILES="$(git -C "$MAIN_WT" diff --cached --name-only)"
    if [ -n "$FILES" ]; then
      git_commit "$MAIN_WT" "swarm: acceptance tests for $FEATURE" || die "could not commit tests"
    fi
    release_lock
    jq -cn --arg feature "$FEATURE" --arg files "$FILES" \
      '{status: "ok", feature: $feature, committed: ($files | split("\n") | map(select(. != "")))}'
    ;;
  diff)
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" || die "no branch $BRANCH"
    BASE="$(git -C "$REPO" merge-base HEAD "$BRANCH")"
    OUT="$SWARM_DIR/runs/$FEATURE/feature.diff"
    mkdir -p "$(dirname "$OUT")"
    git -C "$REPO" diff "$BASE" "$BRANCH" >"$OUT"
    jq -cn --arg feature "$FEATURE" --arg branch "$BRANCH" --arg diff "$OUT" \
      --arg stat "$(git -C "$REPO" diff --shortstat "$BASE" "$BRANCH")" \
      --arg files "$(git -C "$REPO" diff --name-only "$BASE" "$BRANCH")" \
      '{status: "ok", feature: $feature, branch: $branch, diff: $diff, stat: ($stat | ltrimstr(" ")),
        files: ($files | split("\n") | map(select(. != "")))}'
    ;;
  pr)
    need gh
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" || die "no branch $BRANCH"
    git -C "$REPO" remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote to push to"
    BASE_BRANCH="${ARG:-$(git -C "$REPO" rev-parse --abbrev-ref HEAD)}"
    [ "$BASE_BRANCH" != HEAD ] || die "not on a branch; pass the base branch as the third argument"
    HEAD_BRANCH="swarm/$FEATURE"
    REQUEST="$(cat "$PLAN/REQUEST.txt" 2>/dev/null)"
    TITLE="$(printf '%s' "${REQUEST:-swarm: $FEATURE}" | head -n 1 | cut -c 1-70)"
    BODY="$SWARM_DIR/runs/$FEATURE/pr-body.md"
    mkdir -p "$(dirname "$BODY")"
    {
      [ -z "$REQUEST" ] || printf '%s\n\n' "$REQUEST"
      echo "## Tasks"
      echo
      echo "| Task | Result | Model | Attempts |"
      echo "|---|---|---|---|"
      for r in "$SWARM_DIR/runs/$FEATURE"/*/result.json; do
        [ -f "$r" ] || continue
        jq -r '"| \(.id) | \(.status) | \(.model) | \(.attempts) |"' "$r"
      done
      echo
      echo "Every task marked pass cleared its acceptance command before it was merged. Built with the swarm plugin for Claude Code."
    } >"$BODY"
    git -C "$REPO" push -q origin "$BRANCH:refs/heads/$HEAD_BRANCH" >&2 || die "could not push $HEAD_BRANCH to origin"
    URL="$(cd "$REPO" && gh pr create --base "$BASE_BRANCH" --head "$HEAD_BRANCH" --title "$TITLE" --body-file "$BODY")" \
      || die "pushed $HEAD_BRANCH but gh could not open the pull request"
    jq -cn --arg feature "$FEATURE" --arg url "$URL" --arg head "$HEAD_BRANCH" --arg base "$BASE_BRANCH" \
      '{status: "ok", feature: $feature, url: $url, head: $head, base: $base}'
    ;;
  cleanup)
    if [ -d "$SWARM_DIR/worktrees/$FEATURE" ]; then
      for wt in "$SWARM_DIR/worktrees/$FEATURE"/*; do
        [ -d "$wt" ] || continue
        git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
      done
      rmdir "$SWARM_DIR/worktrees/$FEATURE" 2>/dev/null
    fi
    git -C "$REPO" worktree prune
    git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/swarm/$FEATURE/" | while IFS= read -r b; do
      [ "$b" = "$BRANCH" ] || git -C "$REPO" branch -q -D "$b" >/dev/null 2>&1
    done
    rm -rf "$SWARM_DIR/locks/$FEATURE"
    jq -cn --arg feature "$FEATURE" --arg branch "$BRANCH" '{status: "ok", feature: $feature, kept: $branch}'
    ;;
  *)
    die "unknown action: $ACTION"
    ;;
esac
