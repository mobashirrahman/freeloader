# swarm reference

A Claude Code plugin that builds features with free models doing the typing.

- **Opus** plans the feature once, as small task files with an acceptance command each.
- **Sonnet** (your Claude Code session) orchestrates and reads one-line verdicts.
- **Free opencode models** write the code and review it, one git worktree per task.
- **A shell gate** runs the acceptance command, so no model's "done" is taken on trust.

Claude tokens go to planning and one final review. Everything in between is free-tier.

## Requirements

- Claude Code
- [opencode](https://opencode.ai) v2, signed in (`opencode auth login`)
- `git`, `jq`, and one of `timeout`, `gtimeout`, or `perl`
- `gh`, only if you want pull requests opened for you
- macOS or Linux (Windows through WSL)

## Install

```
/plugin marketplace add mobashirrahman/claude-code-agent-swarm
/plugin install swarm@claude-code-agent-swarm
/swarm:doctor
```

## Use

In a git repository with at least one commit, on the Sonnet model:

```
/swarm:build add a slugify helper with tests
```

You approve the plan once. The work lands on a branch named `swarm/<feature>/main`; nothing touches your checked-out branch until you merge it or open a pull request from it.

| Command | What it does |
|---|---|
| `/swarm:build <request>` | Plan, build, and review a feature |
| `/swarm:resume [feature]` | Continue a build that was interrupted |
| `/swarm:stats [feature]` | Pass rates per model, rate limits, escalations |
| `/swarm:doctor [--ping]` | Check that opencode and the models are usable |

## How a task runs

`scripts/run-task.sh <feature> <task-file>` does this and prints one JSON line:

1. Picks the coder models: the task tier's own models first, then the general chain ordered by recorded pass rate, minus any in a rate-limit cooldown.
2. Opens one to three lanes, by tier. Each lane is its own worktree with its own share of the models, so lanes never compete for one model's quota.
3. In each lane, runs the coder through `opencode run`, discards changes to protected files, and checks that only allowed files changed.
4. Runs the task's acceptance command, plus any `gate.commands`.
5. Sends the diff to the reviewer model for a JSON verdict.
6. On any failure, feeds the reason back to the coder, up to `roundsPerModel` times, then moves to the lane's next model with a clean tree.
7. The first lane to pass wins and the others are stopped. The winner is merged into the feature branch, and the gate runs again if other tasks merged in the meantime.

If every free model fails, the orchestrator has a Sonnet subagent finish the task in the same worktree, and `run-task.sh --verify-only` gates and merges it.

## What keeps weak models honest

- **The architect writes the tests.** Opus writes the acceptance tests during planning and they are committed to the feature branch before any coder runs. Each task lists them under `protect`, and the runner throws away any edit a coder makes to them.
- **The plan is checked before it runs.** `scripts/check-plan.sh` rejects a plan with a missing acceptance command, an unknown or circular dependency, or two parallel tasks that may edit the same file. It also returns the run order as waves.
- **Rate limits are remembered.** A model that returns a 429 is skipped for `quota.cooldownSec` (30 minutes by default) across all tasks, and no attempt is spent on it. If every model is cooling, they are all tried anyway.

- **Tasks are tiered.** The architect marks each task `easy`, `normal`, or `hard`. By default one, two, or three models race on it, and `tiers.hard.models` can name stronger models to try first on hard tasks.
- **Results are recorded.** Every attempt goes into `.swarm/ledger.jsonl`. Models are tried in order of their recorded pass rate, and `/swarm:stats` shows the numbers.
- **Builds survive interruption.** Plans, results, and branches are on disk. A task that already passed is not run again, and `/swarm:resume` carries on from what is left.

A coder can still write code that special-cases the visible tests. The reviewer prompt and the final Opus review look for that; nothing mechanical prevents it yet.

Logs for each task are in `.swarm/runs/<feature>/<task-id>/`. The `.swarm` directory is added to `.git/info/exclude`, not to your `.gitignore`.

## Configure

Defaults are in [`swarm.config.default.json`](../swarm.config.default.json). To override, put a `swarm.config.json` at your repository root; it is merged over the defaults.

```json
{
  "coder": { "models": ["opencode/nemotron-3-ultra-free"] },
  "worktree": { "setup": ["npm ci"] },
  "gate": { "commands": ["npm run lint"] }
}
```

| Key | Purpose |
|---|---|
| `coder.models` | The coder models. Any `provider/model` from `opencode models`. |
| `coder.autoOrder` | Try models in order of recorded pass rate (default `true`). Set `false` to keep the configured order. |
| `tiers.<tier>.race` | How many lanes race on a task of that tier. Defaults: easy 1, normal 2, hard 3. |
| `tiers.<tier>.models` | Models tried first for that tier, ahead of `coder.models`. |
| `coder.roundsPerModel`, `coder.maxAttempts` | Feedback rounds per model, and the total cap. |
| `coder.shellDeny` | Shell command prefixes the coder may not run. |
| `reviewer.models` | Reviewer fallback chain. |
| `reviewer.required` | If `true`, a task fails when no reviewer returns a verdict. Default `false`: the gate alone decides. |
| `gate.commands` | Extra commands every task must pass, such as lint or typecheck. Not the full test suite: tests for unfinished tasks fail by design. |
| `worktree.setup` | Commands run in each fresh worktree, such as installing dependencies. |
| `scope.ignore` | Build junk that is never committed or counted as a scope violation. |
| `scope.protect` | Paths no coder may change in any task, on top of each task's own `protect` list. |
| `quota.cooldownSec` | How long a rate-limited model is skipped. |

Free model names change. `/swarm:doctor` tells you when a configured model is gone and lists the free ones on offer.

## Safety

- The coder runs with `opencode run --auto` in its own worktree. Its agent may read, search, edit, and run shell commands; writing outside the worktree, web access, and the `shellDeny` prefixes are denied by opencode.
- The shell deny list is a guardrail, not a sandbox. A model can still reach the network or other files through a shell command that is not on the list. Do not run this on a machine with secrets you would not expose to an unreviewed script.
- Agents are injected for each run with a private opencode server and an empty config directory. Your own opencode config, MCP servers, and plugins are not read or changed.
- Free model providers may log or train on what they are sent. Check their terms before using this on private code.
- Task commits and merges on `swarm/*` branches skip your git hooks.

## Layout

```
.claude-plugin/   plugin and marketplace manifests
agents/           architect (Opus)
skills/           build, resume, stats, doctor
scripts/          run-task.sh, check-plan.sh, feature.sh, status.sh, stats.sh, doctor.sh, lib.sh
opencode/         coder and reviewer prompts
```
