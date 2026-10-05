# Contributing

Bug reports, ideas, and pull requests are all welcome. This is a small project, so there is not much process.

## Getting set up

You need `git`, `jq`, and bash. You do not need opencode or any model access to work on the scripts: the test suite replaces opencode with a stand-in.

```
git clone https://github.com/mobashirrahman/freeloader
cd freeloader
tests/run.sh
```

To try your checkout as a plugin without installing it:

```
claude --plugin-dir /path/to/freeloader
```

## How the code is laid out

| Path | What lives there |
|---|---|
| `scripts/` | The task runner. Plain bash, no model calls except through `opencode run`. |
| `skills/` | What the orchestrating Claude session is told to do for each slash command. |
| `agents/architect.md` | The planner's instructions, including the task file format. |
| `opencode/` | Prompts for the free coder and reviewer models. |
| `tests/` | End-to-end tests and the opencode stand-in. |

The scripts hold the logic and the skills stay thin on purpose. Anything that can be decided by a script should be, because a script costs no tokens and behaves the same way every time.

## Conventions

- Scripts target bash 3.2, the version macOS ships. That rules out associative arrays, `mapfile`, and `${var,,}`.
- Every script prints exactly one JSON line on stdout. Anything meant for a human goes to stderr.
- A change to how a task runs needs a test in `tests/run.sh`. Each test builds a throwaway git repository and drives the real scripts, so they read like usage examples.
- CI runs the suite on Linux and macOS and runs ShellCheck. Run `shellcheck scripts/*.sh` locally if you have it.

## Pull requests

Keep them focused: one change per PR is much easier to review than three. Say what you changed, why, and how you tested it. If you are planning something large, open an issue first so we can agree on the shape before you spend the time.
