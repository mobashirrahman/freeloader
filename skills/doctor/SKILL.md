---
name: doctor
description: Check that the freeloader workflow can run here, covering opencode, git, jq, and the configured free models. Use when the user runs /freeloader:doctor or a freeloader build fails at preflight.
argument-hint: "[--ping]"
---

# Freeloader doctor

Run `"${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" $ARGUMENTS` from the user's repository.

It prints a checklist on stderr and one JSON line on stdout. Report the result in a few lines:

- If `status` is `ok`, say so and list any warnings.
- If a model is reported as not on offer, the free model line-up has changed. The failure message lists the free models currently available; suggest the user put working ones in a `freeloader.config.json` at the repository root, for example `{"coder": {"models": ["opencode/<model>"]}}`. Project settings are merged over the plugin defaults.
- If opencode is missing, point the user to https://opencode.ai to install it and to `opencode auth login` to sign in.

`--ping` sends one small request to every configured model to prove it answers. Free tiers have small quotas, so only use it when the user asks or when models are listed but tasks keep failing with quota or error.
