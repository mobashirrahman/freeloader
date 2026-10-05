---
name: build
description: Build a feature with the freeloader workflow, where a planner writes tests and small tasks, free opencode models write and review the code behind a test gate, and you orchestrate. Use when the user runs /freeloader:build or asks to build something "with the freeloader".
argument-hint: <what to build>
disable-model-invocation: true
---

# Freeloader build

You are the orchestrator. Every turn you take re-reads this whole conversation, so the cheapest build is the one with the fewest turns and the least text in them. A short build with no failures is three tool calls: start, plan, and run.

- Do not read source files, diffs, or logs. Do not write or fix code.
- Do not narrate between steps, and do not repeat script output back.
- Every script prints one JSON line. Run them from the user's repository.

Feature request: $ARGUMENTS

## 1. Start

Pick a short kebab-case feature name and run:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" start <feature> "<the feature request>"
```

It runs the preflight too. If `status` is `fail`, show the `problems` and stop. Otherwise it returns the `plan` directory, the feature `worktree`, and `planner`.

## 2. Plan

Spawn one planning agent in plan mode, giving it the feature request, the plan directory, and the worktree path. It writes the acceptance tests and the task files and replies with a table.

Which agent, from `planner`:

- `sonnet`: `freeloader:planner`.
- `opus`: `freeloader:architect`.
- `auto`: use `freeloader:planner` when the request already states the behaviour it wants and looks like a few files of work. Use `freeloader:architect` when the request is vague, leaves design decisions open, or spans many parts of the codebase. When unsure, use the planner.

Show the user the table and ask whether to proceed. This is the one checkpoint.

## 3. Run

```
"${CLAUDE_PLUGIN_ROOT}/scripts/run-plan.sh" <feature>
```

One call checks the plan, commits the tests, and runs every task in dependency order, in parallel where it can. Run it in the foreground with a 10 minute timeout; it returns within nine. Read `status`:

- `running`: the build is still going. Run the same command again straight away, in the foreground, and keep doing so until the status changes. The command itself does the waiting. Nothing will notify you when the build finishes, so do not end your turn, wait, or schedule a check: ending your turn here abandons the build.
- `pass`: everything is merged. Go to step 4.
- `plan_invalid`: send `problems` to the planning agent in revise mode, then run this again.
- `incomplete`: handle each id in `failed` as below, then run this again. It skips what already passed.

For a failed task, look at its `stage`:

| stage | what to do |
|---|---|
| `scope` | The coder needed a file the task did not allow. Planning agent, revise mode, with the task file path and `detail`. |
| `coder`, with quota or error in `detail` | Free models are unavailable. Tell the user and stop, or escalate if they prefer. |
| anything else | Escalate. |

**Escalate:** the attempt is still in the task's `worktree`. Spawn one general-purpose subagent on the `sonnet` model with the task file path, the worktree path, and the `detail`, telling it to finish the task inside that worktree, change only the task's allowed files, leave protected files alone, and not commit. Then run:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/run-task.sh" --verify-only <feature> <plan-dir>/<id>.md
```

Revise or escalate a given task once. If it still fails, stop and report it along with everything that depends on it.

## 4. Review, only if asked for

If `review` is `skip`, do not review: the tests have decided. If it is `needed`, spawn `freeloader:architect` in review mode with the `diff` path and the original request. On `CHANGES NEEDED`, have it write follow-up task files in revise mode, run step 3 again, and review once more. Two rounds at most.

## 5. Hand over

Tell the user in a few lines: how many tasks passed on free models and how many needed escalation (from `tasks`), whether a review ran and what it said, and the branch name. Then offer two ways to take the work, and do whichever they pick. Do not merge or push before they choose.

- **Merge locally:** `git merge freeloader/<feature>/main`.
- **Open a pull request:** `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" pr <feature>`, which needs the `gh` CLI. Report the `url`.

Afterwards, or if they abandon the feature, run `"${CLAUDE_PLUGIN_ROOT}/scripts/feature.sh" cleanup <feature>`.

If the session is interrupted, nothing is lost: `/freeloader:resume` picks the build up again.
