# Results

> Incomplete: the freeloader run of `6-query` did not execute (the session ended in 5 seconds at $0.00 before doing any work). Its 0/59 is not a measurement and that cell needs re-running.

### Correctness: hidden tests passed

| Task | Sonnet alone | Opus alone | freeloader |
|---|---|---|---|
| 1-slugify | 12/12 | 12/12 | 12/12 |
| 2-cart-remove | 9/9 | 9/9 | 9/9 |
| 3-discounts | 24/24 | 24/24 | 24/24 |
| 4-shipping | 40/40 | 40/40 | 40/40 |
| 5-orders | 30/30 | 30/30 | 30/30 |
| 6-query | 59/59 | 59/59 | 0/59 |

### Claude cost per task (USD)

| Task | Sonnet alone | Opus alone | freeloader |
|---|---|---|---|
| 1-slugify | 0.08 | 0.27 | 0.39 |
| 2-cart-remove | 0.10 | 0.18 | 0.35 |
| 3-discounts | 0.11 | 0.33 | 0.67 |
| 4-shipping | 0.13 | 0.27 | 0.61 |
| 5-orders | 0.16 | 0.41 | 0.80 |
| 6-query | 0.18 | 0.47 | 0.00 |

### Wall time per task

| Task | Sonnet alone | Opus alone | freeloader |
|---|---|---|---|
| 1-slugify | 0m 13s | 0m 24s | 1m 50s |
| 2-cart-remove | 0m 22s | 0m 24s | 1m 45s |
| 3-discounts | 0m 35s | 1m 01s | 4m 03s |
| 4-shipping | 0m 29s | 0m 46s | 4m 06s |
| 5-orders | 0m 38s | 1m 15s | 4m 12s |
| 6-query | 0m 53s | 1m 51s | 0m 05s |

### Totals

| Arm | Tasks fully solved | Hidden tests | Existing tests | Claude cost | Wall time |
|---|---|---|---|---|---|
| Sonnet alone | 6/6 | 174/174 | 102/102 | 0.76 | 3m 10s |
| Opus alone | 6/6 | 174/174 | 102/102 | 1.93 | 5m 41s |
| freeloader | 5/6 | 115/174 | 102/102 | 2.82 | 16m 01s |

### Inside the freeloader runs

| Task | Subtasks planned | Passed on free models | Escalated to Sonnet | Not passed | Free-model attempts | Opus cost | Sonnet cost |
|---|---|---|---|---|---|---|---|
| 1-slugify | 1 | 1 | 0 | 0 | 1 | 0.23 | 0.15 |
| 2-cart-remove | 1 | 1 | 0 | 0 | 1 | 0.21 | 0.14 |
| 3-discounts | 2 | 2 | 0 | 0 | 2 | 0.47 | 0.20 |
| 4-shipping | 2 | 2 | 0 | 0 | 2 | 0.41 | 0.20 |
| 5-orders | 3 | 3 | 0 | 0 | 3 | 0.56 | 0.24 |
| 6-query | 0 | 0 | 0 | 0 | 0 | 0.00 | 0.00 |

### Free models

| Model | Attempts | Passes | Rate limited | Refused |
|---|---|---|---|---|
| opencode/muse-spark-1.3-contributor-free | 9 | 9 | 0 | 0 |

Run on 2026-10-05 with 2.1.289 (Claude Code), freeloader at commit b106fab.
