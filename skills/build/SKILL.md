---
name: build
description: Build a feature with the swarm workflow, where Opus plans, free opencode models write and review the code behind a test gate, and you orchestrate. Use when the user runs /swarm:build or asks to build something "with the swarm".
argument-hint: <what to build>
disable-model-invocation: true
---

# Swarm build

You are the orchestrator. Your job is to dispatch work and read one-line verdicts. The point of this workflow is to spend as few Claude tokens as possible, so:

- Do not read source files, diffs, or logs yourself. The architect reads code; the scripts check it.
- Do not write or fix code yourself.
- Do not paste script output back to the user beyond a one-line status per task.

Every script below prints exactly one JSON line. Run them from the user's repository.

Feature request: $ARGUMENTS

## 1. Preflight

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"`. If `status` is `fail`, show the problems and stop. Mention warnings once and continue.

Pick a short kebab-case feature name, then run `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" start <feature> "<the feature request>"`. It records the request and returns the `plan` directory and the feature `worktree`.

## 2. Plan

Spawn the `swarm:architect` agent in plan mode with the feature request, the plan directory, and the worktree path. It writes acceptance tests into the worktree and task files into the plan directory, and returns a table of id, title, tier, and depends.

Then run these two, in order:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/check-plan.sh" <feature>
"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" commit-tests <feature>
```

If `check-plan.sh` returns `status: fail`, send its `problems` back to the architect in revise mode and check again; do not start work on a failing plan. Its `waves` field is the run order: every task in a wave can run in parallel once all earlier waves have passed.

Show the user the table and the waves, and ask whether to proceed. This is the one checkpoint before work starts.

## 3. Run the tasks

Run each task with:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/run-task.sh" <feature> <plan-dir>/<id>.md
```

A task can take several minutes; use a 30 minute timeout. Go wave by wave. Within a wave, run tasks at the same time as background commands, at most three at once, and start the next wave only when every task in the current one has status `pass`.

The script decides for itself how many free models to race on a task and which to try first, from the task's tier and from how each model has done so far. A task that already passed returns at once with `cached: true`, so calling a finished task again is harmless.

Read only `status`, `stage`, `model`, `attempts`, and `detail` from the result:

| status | meaning | what to do |
|---|---|---|
| `pass` | merged into the feature branch | next task |
| `fail`, stage `coder` and detail mentions quota or error | every free coder model is rate-limited or down | tell the user; wait and retry later, or escalate |
| `fail`, stage `scope` | coder needed a file the task did not allow | architect, revise mode |
| `fail`, stage `gate` or `review` | free models could not get it right | escalate |
| `conflict` or `integration_fail` | passed alone, clashes with another task | run it again; it restarts from the updated feature branch |
| `error` | bad task file or setup problem | fix what `error` says, or architect in revise mode |

**Revise:** spawn `swarm:architect` in revise mode with the task file path and the `detail`. Run `check-plan.sh` again, run `feature.sh commit-tests` if it changed a test, then run the task files it returns. Revise a given task at most once.

**Escalate:** the failed attempt is still in the `worktree` path from the result. Spawn one general-purpose subagent on the `sonnet` model with the task file path, the worktree path, and the `detail`, telling it to finish the task inside that worktree, change only the task's allowed files, leave protected files alone, and not commit. Then run:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/run-task.sh" --verify-only <feature> <plan-dir>/<id>.md
```

If that still fails, stop work on this task and on everything that depends on it, and report it.

## 4. Final review

When every task has passed, run `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" diff <feature>` and spawn `swarm:architect` in review mode with the `diff` path and the original request.

If it answers `CHANGES NEEDED`, have it write follow-up task files in revise mode, run them, and review once more. Do at most two review rounds.

## 5. Hand over

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/stats.sh" <feature>` and report to the user: tasks passed on free models, tasks that needed escalation, which model did most of the work, the reviewer's verdict, and the branch name `swarm/<feature>/main`.

Do not merge or push anything yourself. Offer the user two ways to take the work, and do whichever they pick:

- **Merge locally:** `git merge swarm/<feature>/main`.
- **Open a pull request:** `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" pr <feature>` pushes the branch to `origin` and opens a PR against the branch they have checked out. It needs the `gh` CLI. Report the `url` it returns.

After they have merged or opened the PR, or if they abandon the feature, run `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" cleanup <feature>`.

## If the session is interrupted

Nothing is lost: plans, results, and branches are on disk. `/swarm:resume` picks the build up again.
