# Benchmark

Does handing the typing to free models save anything, and does the code still work? This compares the same requests run three ways:

| Arm | What runs |
|---|---|
| Sonnet alone | A plain Claude Code session on Sonnet |
| Opus alone | A plain Claude Code session on Opus |
| freeloader | `/freeloader:build` in a Sonnet session: Claude plans, free models code. Run for versions 1.0.0 and 1.1.0. |

Results are in [RESULTS.md](RESULTS.md).

## How it works

- **The project.** [`fixture/`](fixture) is a small Python package, `shopkit`, with a catalog, a cart, a command line tool, and 17 tests. Every session starts from a fresh copy of it in its own git repository.
- **The tasks.** Six requests in [`tasks/`](tasks), from a one-function helper to a query language with a parser:

  | Task | Size | What it asks for |
  |---|---|---|
  | `1-slugify` | small | One new function |
  | `2-cart-remove` | small | Fix a bug in existing code |
  | `3-discounts` | medium | Three discount types and how they combine |
  | `4-shipping` | medium | Weight parsing and shipping rates by zone |
  | `5-orders` | large | Inventory, an order state machine, and a CLI command |
  | `6-query` | large | A query language: tokenizer, parser, catalog and CLI integration |

- **The same words for everyone.** Each arm gets the task's `request.md` verbatim. The only difference is a closing line telling the session nobody is there to answer questions, and, for freeloader, that the plan is approved in advance.
- **Hidden tests decide.** Each task has a test suite in `hidden/` that no session ever sees: 174 tests in all. After a session ends, they are copied in and run against whatever it produced. A task counts as solved only if every hidden test passes.
- **The hidden tests are checked.** Each task also has a reference solution. The harness refuses to run unless every reference passes its hidden tests, so a failing score means the code is wrong, not the test.
- **Nothing regresses quietly.** The fixture's original 17 tests are run too, from a clean copy, so a session cannot pass by editing them.

## What is measured

- **Hidden tests passed**, per task.
- **Claude cost**, as reported by Claude Code for the session, split by model. Free-model usage costs nothing and is not in this number.
- **Wall time** for the whole session.
- For freeloader: how many subtasks the architect planned, how many passed on free models, how many had to be escalated to a Sonnet subagent, and how each free model did.

## Running it

```
bench/run.py --arms sonnet,opus --jobs 3 --out bench/results/baselines.json
bench/run.py --arms freeloader --out bench/results/freeloader.json
bench/report.py bench/results/baselines.json bench/results/freeloader.json
```

It needs `claude`, `git`, `python3`, and `pytest`, plus opencode for the freeloader arm. It spends real Claude usage: a few dollars for the full set.

`--tasks` runs a subset, `--plugin-dir` points the freeloader arm at another checkout so that two versions can be compared, and `report.py` takes `LABEL=FILE` to give a results file its own column.

## What this does not tell you

- **One run per cell.** Models are not deterministic, and a single run cannot separate a real difference from luck. Treat small gaps as noise.
- **Small, well-specified tasks.** Every request spells out the exact behaviour wanted. Vague requests, large codebases, and long features are where a planner should matter most, and none of that is here.
- **Python only**, in a project with no dependencies to install.
- **A moving target.** Free model line-ups, their rate limits, and what the provider will serve all change. A result from one day may not hold the next.
- **Cost is Claude's reported cost.** On a subscription plan the number that matters to you is usage against your limit, which this approximates but does not equal.
