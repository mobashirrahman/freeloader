#!/usr/bin/env python3
"""Turn benchmark result files into Markdown tables.

    bench/report.py bench/results/baselines.json "freeloader 1.0.0=bench/results/freeloader.json"

An argument is a results file, or LABEL=FILE to show that file's runs under a
column of their own, which is how two versions of freeloader are compared. When
two files hold the same column and task, the later file wins, so a cell can be
re-run on its own.
"""

import json
import sys
from pathlib import Path

ARM_NAMES = {"sonnet": "Sonnet alone", "opus": "Opus alone", "freeloader": "freeloader"}


def load(args):
    runs, cells, order = [], {}, []
    for arg in args:
        label, _, path = arg.rpartition("=")
        run = json.loads(Path(path).read_text())
        runs.append(run)
        for result in run["results"]:
            column = label or ARM_NAMES.get(result["arm"], result["arm"])
            result = dict(result, column=column, commit=run["freeloader_commit"])
            if column not in order:
                order.append(column)
            cells[column, result["task"]] = result
    return runs, cells, order


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(lines)


def minutes(seconds):
    return f"{seconds // 60}m {seconds % 60:02d}s"


def main():
    runs, cell, arms = load(sys.argv[1:])
    tasks = sorted({task for _, task in cell})
    free = [a for a in arms if "freeloader" in cell[a, tasks[0]]]

    def per_task(title, value):
        print(f"\n### {title}\n")
        print(table(["Task"] + arms, [[task] + [value(cell[a, task]) for a in arms] for task in tasks]))

    print("### Totals\n")
    rows = []
    for arm in arms:
        mine = [cell[arm, t] for t in tasks]
        rows.append([
            arm,
            f"{sum(r['solved'] for r in mine)}/{len(mine)}",
            f"{sum(r['hidden_passed'] for r in mine)}/{sum(r['hidden_total'] for r in mine)}",
            f"{sum(r['original_passed'] for r in mine)}/{sum(r['original_total'] for r in mine)}",
            f"${sum(r['cost_usd'] for r in mine):.2f}",
            minutes(sum(r["seconds"] for r in mine)),
        ])
    print(table(["", "Tasks fully solved", "Hidden tests", "Existing tests", "Claude cost", "Wall time"], rows))

    per_task("Hidden tests passed", lambda r: f"{r['hidden_passed']}/{r['hidden_total']}")
    per_task("Claude cost per task", lambda r: f"${r['cost_usd']:.2f}")
    per_task("Wall time per task", lambda r: minutes(r["seconds"]))

    for arm in free:
        print(f"\n### Inside the {arm} runs\n")
        rows = []
        for task in tasks:
            r = cell[arm, task]
            d = r["freeloader"]
            by_model = r.get("cost_by_model", {})
            opus = sum(v for k, v in by_model.items() if "opus" in k)
            sonnet = sum(v for k, v in by_model.items() if "sonnet" in k)
            attempts = sum(m["attempts"] for m in d["models"].values())
            rows.append([task, d["planned_tasks"], d["tasks_passed_free"], d["tasks_escalated"],
                         attempts, f"${opus:.2f}", f"${sonnet:.2f}"])
        print(table(["Task", "Subtasks planned", "Passed on free models", "Escalated to Sonnet",
                     "Free-model attempts", "Opus cost", "Sonnet cost"], rows))

    models = {}
    for arm in free:
        for task in tasks:
            for name, m in cell[arm, task]["freeloader"]["models"].items():
                total = models.setdefault(name, {"attempts": 0, "passes": 0, "quota": 0, "refused": 0, "error": 0})
                for key in total:
                    total[key] += m.get(key, 0)
    if models:
        print("\n### Free models, across all freeloader runs\n")
        print(table(["Model", "Attempts", "Passes", "Rate limited", "Refused", "Errors"], [
            [name.split("/", 1)[-1], m["attempts"], m["passes"], m["quota"], m["refused"], m["error"]]
            for name, m in sorted(models.items(), key=lambda kv: -kv[1]["attempts"])
        ]))

    commits = {arm: sorted({cell[arm, t]["commit"] for t in tasks}) for arm in free}
    print("\nRun on " + ", ".join(sorted({run["date"] for run in runs}))
          + " with Claude Code " + ", ".join(sorted({run["claude_code"].split()[0] for run in runs}))
          + ". " + " ".join(f"{arm} is commit {', '.join(c)}." for arm, c in commits.items()))


if __name__ == "__main__":
    main()
