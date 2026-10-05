# Reference

The [README](../README.md) covers what freeloader is and how to start. This page is for when you want to tune it, read its output, or understand what a script is doing.

- [How a task runs](#how-a-task-runs)
- [Task files](#task-files)
- [Results](#results)
- [Configuration](#configuration)
- [What the models can do](#what-the-models-can-do)
- [Egress proxies](#egress-proxies)
- [Scripts](#scripts)
- [What it leaves in your repository](#what-it-leaves-in-your-repository)
- [Safety](#safety)

## How a task runs

`scripts/run-task.sh <feature> <task-file>` takes one task from nothing to merged:

1. **Pick the models.** The task tier's own models go first, then the general list ordered by recorded pass rate. Models in a rate-limit cooldown are left out.
2. **Open the lanes.** One to three, depending on the tier. Each lane is its own git worktree and gets its own share of the models, so two lanes never compete for one model's quota.
3. **Code.** In each lane the coder model runs through `opencode run` with the task file as its prompt.
4. **Scope.** Changes to protected files are thrown away. Changes outside the task's `files` list fail the attempt.
5. **Gate.** The task's `accept` command runs, followed by any `gate.commands`. Exit code 0 or it did not happen.
6. **Review.** A second free model reads the diff against the task and returns a JSON verdict.
7. **Retry.** A failure at any step goes back to the coder as feedback, up to `roundsPerModel` times. After that the lane moves to its next model and starts from a clean tree.
8. **Merge.** The first lane to pass wins and the others are stopped. The winner is merged into the feature branch. If other tasks merged in the meantime, the gate runs once more on the combined result, and the merge is rolled back if it fails.

If every free model fails, the orchestrator hands the worktree to a Sonnet subagent, then runs `run-task.sh --verify-only` so that the fix goes through the same scope check, gate, and merge.

## Task files

The architect writes one Markdown file per task into `.freeloader/plan/<feature>/`. You can write or edit them by hand too.

```
---
id: 001-slugify
accept: python3 -m pytest tests/test_slug.py -q
tier: normal
files:
  - src/slug.py
protect:
  - tests/test_slug.py
depends:
  - 000-setup
---
# Add slugify()

What to build: exact names, signatures, behaviours, and edge cases.
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Letters, digits, `.`, `_`, `-`. Must match the file name. |
| `accept` | yes | One shell command, run from the repository root. Exit 0 means the task is done. |
| `files` | yes | Paths or globs the coder may change. A trailing `/` allows a whole directory. |
| `protect` | no | Paths the coder must not change, usually the tests the architect wrote. |
| `depends` | no | Ids of tasks that must pass first. |
| `tier` | no | `easy`, `normal` (default), or `hard`. Sets how many models race and which go first. |

Everything after the front matter is the prompt the coder sees, along with the allowed files, the protected files, and the acceptance command. The coder has not seen your conversation, so the task has to stand on its own.

`scripts/check-plan.sh <feature>` validates a plan before anything runs. It rejects missing fields, unknown or circular dependencies, and pairs of tasks that could run at the same time while editing the same file. It also returns the tasks grouped into waves: everything in a wave can run in parallel once the earlier waves have passed.

## Results

Every script prints one JSON line. For a task it looks like this (trimmed):

```json
{"status":"pass","id":"001-acronym","tier":"hard","stage":"done",
 "model":"opencode/muse-spark-1.3-contributor-free","attempts":1,"lanes":3,
 "seconds":18,"review":"pass","files":["textkit/acronym.py"]}
```

| `status` | `stage` | What happened |
|---|---|---|
| `pass` | `done` | Merged into the feature branch. `cached: true` means it had already passed and was not run again. |
| `fail` | `coder` | The model made no changes, or every model was rate-limited, refused the request, or was unavailable. |
| `fail` | `scope` | The coder changed a file the task does not allow. |
| `fail` | `gate` | The acceptance command still fails after all attempts. |
| `fail` | `review` | The gate passes but the reviewer keeps rejecting the change. |
| `conflict` | `merge` | Passed alone, but does not merge cleanly with a task that landed first. Run it again. |
| `integration_fail` | `merge` | Merged cleanly, but the gate fails on the combined code. Run it again. |
| `error` | | Bad task file or a setup problem. `error` or `detail` says which. |

On a failure, `detail` holds the last feedback the coder was given and `worktree` points at the attempt, which is left in place. Full logs are in `.freeloader/runs/<feature>/<task-id>/`: the opencode event stream for each coder and reviewer call, and the output of each gate run.

## Configuration

Defaults live in [`freeloader.config.default.json`](../freeloader.config.default.json). To change one, create `freeloader.config.json` at your repository root with only the keys you want to override. Settings you want everywhere go in `~/.config/freeloader/config.json`, which is read first; the repository's file wins where both set a key.

```json
{
  "coder": { "models": ["opencode/nemotron-3-ultra-free"] },
  "tiers": { "hard": { "models": ["opencode-go/kimi-k3"] } },
  "worktree": { "setup": ["npm ci"] },
  "gate": { "commands": ["npm run lint"] }
}
```

### Models

| Key | Default | Purpose |
|---|---|---|
| `coder.models` | three free models | Coder models. Any `provider/model` that `opencode models` lists. |
| `coder.autoOrder` | `true` | Try models in order of recorded pass rate. `false` keeps the order you wrote. |
| `coder.roundsPerModel` | `3` | Attempts a model gets on a task, counting feedback rounds. |
| `coder.maxAttempts` | `6` | Cap on attempts per lane, across all its models. |
| `coder.timeoutSec` | `900` | Time limit for one coder call. |
| `reviewer.models` | two free models | Reviewer models, tried in order. |
| `reviewer.required` | `false` | If `true`, a task fails when no reviewer returns a usable verdict. Otherwise the gate alone decides. |
| `tiers.<tier>.race` | 1, 2, 3 | Lanes for easy, normal, and hard tasks. |
| `tiers.<tier>.models` | empty | Models tried first for that tier, ahead of `coder.models`. A good place for a stronger paid model on hard tasks. |
| `quota.cooldownSec` | `1800` | How long a model is skipped after it rate-limits or refuses a request. |
| `coder.web`, `reviewer.web` | `true` | Whether the model may fetch web pages, mainly to read documentation. |

Racing uses free quota faster. If rate limits are your bottleneck, set `tiers.normal.race` to `1`.

### Checks

| Key | Default | Purpose |
|---|---|---|
| `gate.commands` | empty | Extra commands every task must pass, such as lint or a type check. Do not put the full test suite here: the architect's tests for unfinished tasks fail by design. |
| `gate.timeoutSec` | `600` | Time limit for one gate command. |
| `gate.feedbackLines` | `50` | Lines of failing output passed back to the coder. |
| `scope.protect` | empty | Paths no coder may change in any task, on top of each task's own `protect` list. |
| `scope.ignore` | caches, `node_modules` | Build leftovers that are never committed and never count as a scope violation. |

### Environment

| Key | Default | Purpose |
|---|---|---|
| `worktree.setup` | empty | Commands run in every fresh worktree. If your tests need installed dependencies, this is where `npm ci` or a virtualenv goes. |
| `coder.shellDeny` | `git push`, `curl`, `sudo`, `opencode`, ... | Shell command prefixes the coder may not run. |

## What the models can do

Both roles run on opencode's stock `build` agent. Each call gets its own permission config, and anything not listed below is denied, including asking questions, spawning subagents, and MCP tools.

| | Coder | Reviewer |
|---|---|---|
| Read, search, and list files in the worktree | yes | yes |
| Edit files in the worktree | yes | no |
| Touch files outside the worktree | no | no |
| Run shell commands | yes, except `coder.shellDeny` | no |
| Fetch a web page | yes, unless `coder.web` is `false` | yes, unless `reviewer.web` is `false` |
| Web search | no | no |

Why it is set up this way:

- **The coder gets a shell** because a coder that cannot run the tests is guessing. That is also what makes it the risky role, so the deny list covers the commands with consequences outside the worktree: pushing, rewriting history, uploading, and escalating.
- **The coder gets web fetch** because weak models invent library APIs, and reading the documentation is the cheapest fix. Denying it bought little: a model with a shell can already reach the network through `pip`, `npm`, or a line of Python.
- **The reviewer gets no shell and no edits.** Its only output is a verdict, the gate has already run the tests, and a reviewer that can change files could alter what gets merged after it was checked.
- **Web search is off for both.** opencode cancels it in unattended runs, so allowing it would only waste a turn.

Fetched pages are untrusted input to an agent with a shell. Both prompts tell the model to treat them as reference and never follow instructions found in them, but that is a request, not a guarantee. Set `coder.web` to `false` if that risk is not acceptable for your repository.

### When a provider refuses

opencode's free tier does not accept every request. At the time of writing, custom agents are widely reported not to work on it, and in testing it refused the read-only reviewer profile on most free models while accepting the coder profile. freeloader treats a refusal like a rate limit: the model is skipped for `quota.cooldownSec` and the next one is tried.

If no reviewer model accepts, the review is recorded as `skipped` and the task is merged on the acceptance gate alone, unless `reviewer.required` is `true`. `/freeloader:doctor --ping` shows which models are answering in which role.

## Egress proxies

Optional, and off by default. When it is on, every model call leaves through one of your own HTTP proxies instead of directly.

```json
{
  "egress": {
    "mode": "on",
    "proxiesFile": "/path/to/proxies.env",
    "countries": ["US"]
  }
}
```

| Key | Default | Purpose |
|---|---|---|
| `egress.mode` | `off` | `on` routes every coder and reviewer call through an exit. |
| `egress.proxiesFile` | empty | Where the proxy list is. Either a plain list, one per line, or an env file with a `FREELOADER_PROXIES=` or `PI_SWARM_PROXIES=` line. The `FREELOADER_PROXIES` and `FREELOADER_PROXIES_FILE` environment variables override it. |
| `egress.countries` | empty | Use only exits tagged with one of these countries. |
| `egress.retrySec` | `300` | How long an exit that failed to connect is left alone. |

Proxy entries are `http://` or `https://` URLs, optionally tagged with a two-letter country as `US=http://user:pass@host:port` or `http://user:pass@host:port#US`. SOCKS proxies are not supported. Keep the list out of your repository: it contains credentials.

How an exit is chosen:

- One exit is picked at random and then kept, for every task in the repository, so a build has one consistent origin.
- It is replaced only when the exit itself stops connecting. A rate limit or a refusal from a model provider never changes the exit; those are handled by moving to another model, as usual.
- It fails closed. If no exit matches `countries`, or every exit is down, the call fails. Nothing is sent directly.

Credentials never reach the models. Each call gets a small forwarder on `127.0.0.1` that holds the proxy's username and password, and the agent is pointed at that. An agent that prints its own environment sees only a local address. Results and the ledger record a label such as `US-3f2a`, never a host. Using egress needs `node` on your PATH.

Two limits to be clear about. A proxy does not raise anyone's quota, since providers meter by API key. And an agent with a shell can still read files on your disk, including the proxy list itself if it goes looking; the forwarder keeps credentials out of the environment, not out of reach of a determined model. See [Safety](#safety).

## Scripts

The slash commands are thin wrappers around these. They are safe to run by hand from your repository, which is the easiest way to debug a build.

| Script | Does |
|---|---|
| `feature.sh start <feature> [request]` | Creates the feature branch, its worktree, and the plan directory. |
| `check-plan.sh <feature>` | Validates the plan and returns the waves. |
| `feature.sh commit-tests <feature>` | Commits the architect's tests to the feature branch. |
| `run-task.sh <feature> <task-file>` | Runs one task. `--verify-only` gates and merges an existing worktree. `--force` re-runs a task that already passed. |
| `status.sh [feature]` | What has passed and what can run next. |
| `stats.sh [feature]` | Pass rate, rate limits, and timing per model. |
| `feature.sh diff <feature>` | Writes the full feature diff to a file. |
| `feature.sh pr <feature> [base]` | Pushes the branch and opens a pull request with `gh`. |
| `feature.sh cleanup <feature>` | Removes worktrees and task branches. Keeps `freeloader/<feature>/main`. |
| `doctor.sh [--ping]` | Checks tools, the opencode login, and the configured models. |

## What it leaves in your repository

- A `.freeloader/` directory with plans, logs, the ledger, and worktrees. It is added to `.git/info/exclude`, so it never shows up in `git status` and your `.gitignore` is not touched.
- Branches under `freeloader/<feature>/`. The one that matters is `freeloader/<feature>/main`; the rest are per-task and go away on cleanup.
- Nothing else. Your checked-out branch and working tree are not modified until you merge.

Commits on `freeloader/*` branches skip your git hooks, because a pre-commit hook that prompts or needs your environment would stall an unattended run.

## Safety

- The coder runs with `opencode run --auto` inside its worktree. It may read, search, edit, run shell commands, and fetch web pages. Writing outside the worktree and the `shellDeny` prefixes are denied by opencode's permission system. The full list is under [What the models can do](#what-the-models-can-do).
- The deny list is a guardrail, not a sandbox. It matches command prefixes, so a model can reach the network or other files through a command that is not listed. Do not run this on a machine holding secrets you would not expose to a script you have not read.
- Each run uses a private opencode server with an empty config directory. Your own opencode configuration, MCP servers, and plugins are neither read nor changed.
- Your code goes to the model providers you configure. Free tiers often log or train on what they receive, so check their terms before pointing this at private code.
