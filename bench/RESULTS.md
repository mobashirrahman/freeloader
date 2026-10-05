# Results

Six tasks, each run through plain Sonnet, plain Opus, and two versions of freeloader, and scored by hidden tests. The method and its limits are in [README.md](README.md).

## What the numbers say

- **Correctness was never the problem.** Every build that ran to the end passed every hidden test, and the free models did all of the coding: no task had to be handed back to Claude.
- **freeloader 1.0.0 cost about five times what Sonnet alone did.** Opus planning and review were most of it. On the largest task Opus wrote about 16,800 output tokens of tests and instructions so that a free model could write a feature Sonnet produced, tests included, in about 5,700.
- **freeloader 1.1.0 cut its own cost to roughly a third**, by planning small requests on Sonnet, skipping the Opus review on small plans, and running a plan in one call. It is now within reach of Sonnet alone, but still above it, and several times slower.

## Read this before the tables

Each cell is a single run. Three cells were run more than once, and the table shows the last run of each:

| Cell | What happened first | What is shown |
|---|---|---|
| 1.0.0, `6-query` | The session never started; the account's usage limit had been reached. | A later run, which completed. |
| 1.1.0, `3-discounts` | The build was cut off. One command ran past Claude Code's ten-minute limit and the headless session ended with a task in progress. It scored 0 of 24. | A run after `run-plan.sh` was changed to return within nine minutes. |
| 1.1.0, `6-query` | Cut off the same way at 57 of 59, then, on the next try, stalled for 36 minutes when model connections dropped and the timeout did not fire. | That stalled run, scoring 0 of 59. A run on the fixed code is in progress and this row will be updated. |

The other 1.1.0 cells were run before those two fixes. Neither fix changes what a build that finishes in a few minutes does.

Re-running a cell until it works would be cherry-picking if the failures were the models' fault. Here each one was a defect in freeloader, which is listed above and fixed. They are also the most useful thing the benchmark found.

### Totals

|  | Tasks fully solved | Hidden tests | Existing tests | Claude cost | Wall time |
|---|---|---|---|---|---|
| Sonnet alone | 6/6 | 174/174 | 102/102 | $0.76 | 3m 10s |
| Opus alone | 6/6 | 174/174 | 102/102 | $1.93 | 5m 41s |
| freeloader 1.0.0 | 6/6 | 174/174 | 102/102 | $4.11 | 44m 13s |
| freeloader 1.1.0 | 5/6 | 115/174 | 102/102 | $1.10 | 49m 36s |

### Hidden tests passed

| Task | Sonnet alone | Opus alone | freeloader 1.0.0 | freeloader 1.1.0 |
|---|---|---|---|---|
| 1-slugify | 12/12 | 12/12 | 12/12 | 12/12 |
| 2-cart-remove | 9/9 | 9/9 | 9/9 | 9/9 |
| 3-discounts | 24/24 | 24/24 | 24/24 | 24/24 |
| 4-shipping | 40/40 | 40/40 | 40/40 | 40/40 |
| 5-orders | 30/30 | 30/30 | 30/30 | 30/30 |
| 6-query | 59/59 | 59/59 | 59/59 | 0/59 |

### Claude cost per task

| Task | Sonnet alone | Opus alone | freeloader 1.0.0 | freeloader 1.1.0 |
|---|---|---|---|---|
| 1-slugify | $0.08 | $0.27 | $0.39 | $0.13 |
| 2-cart-remove | $0.10 | $0.18 | $0.35 | $0.12 |
| 3-discounts | $0.11 | $0.33 | $0.67 | $0.23 |
| 4-shipping | $0.13 | $0.27 | $0.61 | $0.21 |
| 5-orders | $0.16 | $0.41 | $0.80 | $0.22 |
| 6-query | $0.18 | $0.47 | $1.29 | $0.19 |

### Wall time per task

| Task | Sonnet alone | Opus alone | freeloader 1.0.0 | freeloader 1.1.0 |
|---|---|---|---|---|
| 1-slugify | 0m 13s | 0m 24s | 1m 50s | 1m 16s |
| 2-cart-remove | 0m 22s | 0m 24s | 1m 45s | 1m 30s |
| 3-discounts | 0m 35s | 1m 01s | 4m 03s | 3m 39s |
| 4-shipping | 0m 29s | 0m 46s | 4m 06s | 2m 22s |
| 5-orders | 0m 38s | 1m 15s | 4m 12s | 4m 09s |
| 6-query | 0m 53s | 1m 51s | 28m 17s | 36m 40s |

### Inside the freeloader 1.0.0 runs

| Task | Subtasks planned | Passed on free models | Escalated to Sonnet | Free-model attempts | Opus cost | Sonnet cost |
|---|---|---|---|---|---|---|
| 1-slugify | 1 | 1 | 0 | 1 | $0.23 | $0.15 |
| 2-cart-remove | 1 | 1 | 0 | 1 | $0.21 | $0.14 |
| 3-discounts | 2 | 2 | 0 | 2 | $0.47 | $0.20 |
| 4-shipping | 2 | 2 | 0 | 2 | $0.41 | $0.20 |
| 5-orders | 3 | 3 | 0 | 3 | $0.56 | $0.24 |
| 6-query | 4 | 4 | 0 | 4 | $0.98 | $0.31 |

### Inside the freeloader 1.1.0 runs

| Task | Subtasks planned | Passed on free models | Escalated to Sonnet | Free-model attempts | Opus cost | Sonnet cost |
|---|---|---|---|---|---|---|
| 1-slugify | 1 | 1 | 0 | 1 | $0.00 | $0.13 |
| 2-cart-remove | 1 | 1 | 0 | 1 | $0.00 | $0.12 |
| 3-discounts | 2 | 2 | 0 | 2 | $0.00 | $0.23 |
| 4-shipping | 2 | 2 | 0 | 2 | $0.00 | $0.21 |
| 5-orders | 3 | 3 | 0 | 3 | $0.00 | $0.22 |
| 6-query | 3 | 0 | 0 | 0 | $0.00 | $0.19 |

### Free models, across all freeloader runs

| Model | Attempts | Passes | Rate limited | Refused | Errors |
|---|---|---|---|---|---|
| muse-spark-1.3-contributor-free | 22 | 22 | 0 | 0 | 0 |

Run on 2026-10-05 with Claude Code 2.1.289. freeloader 1.0.0 is commit b106fab. freeloader 1.1.0 is commit 6ab3181.

## Regenerating this

```
bench/report.py bench/results/baselines.json \
  "freeloader 1.0.0=bench/results/freeloader.json" \
  "freeloader 1.0.0=bench/results/freeloader-v1-query.json" \
  "freeloader 1.1.0=bench/results/freeloader-lean.json" \
  "freeloader 1.1.0=bench/results/freeloader-lean-rerun.json"
```

The raw output of every session, including the superseded ones, is in `results/raw/`.
