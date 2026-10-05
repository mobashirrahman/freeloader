---
name: resume
description: Continue a freeloader build that was interrupted, from the tasks that have not passed yet. Use when the user runs /freeloader:resume or asks to continue or check on a freeloader build.
argument-hint: "[feature]"
disable-model-invocation: true
---

# Freeloader resume

A freeloader build keeps its plan, task results, and branches on disk, so it can be continued in a new session.

1. If no feature was given ($ARGUMENTS is empty), run `"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"`. It lists the features with a plan, how many tasks each has passed, and the original request. If exactly one is unfinished, use it; otherwise ask the user which one.

2. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" <feature>`. Tell the user in two or three lines what was asked for (`request`), how far it got (`passed` of `total`), and what runs next (`next`).

3. Then continue exactly as the `freeloader:build` skill describes, with these entry points:
   - `planProblems` is not empty: the plan itself is broken. Send the problems to `freeloader:architect` in revise mode before running anything.
   - `total` is 0: planning never finished. Start from step 2 of the build skill, using `request` as the feature request.
   - `next` is not empty: start from step 3 of the build skill. Run the tasks in `next`, then run `status.sh` again for the next batch, until `done` is true or nothing in `next` will pass.
   - `done` is true: start from step 4 of the build skill, the final review.

A task in `next` whose last `status` was `fail` has already used its free attempts once. Run it once more, since rate limits may have cleared, and escalate if it fails again.

Do not re-plan a feature that already has task files unless the user asks for that.
