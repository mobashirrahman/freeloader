---
name: stats
description: Show how the freeloader's free models have performed in this repository, with pass rates, rate limits, and how many tasks needed escalation. Use when the user runs /freeloader:stats or asks which freeloader model is doing best.
argument-hint: "[feature]"
---

# Freeloader stats

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/stats.sh" $ARGUMENTS` from the user's repository. With a feature name it covers that feature; without one, everything recorded in this repository.

It prints a table on stderr and one JSON line on stdout. Show the user the table and one or two lines on what stands out, for example:

- a model with a low pass rate over five or more attempts, which is worth removing from `coder.models` in `freeloader.config.json`
- a model that is rate-limited often, which is worth moving later in the list
- a tier where few tasks pass on free models, which suggests the architect should split those tasks further or that `tiers.hard.models` should name a stronger model

The runner already tries models in order of recorded pass rate, so the user only needs to edit the config to drop a model or add one.
