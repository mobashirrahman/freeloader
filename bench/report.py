#!/usr/bin/env python3
"""Turn benchmark result files into Markdown tables.

    bench/report.py bench/results/baselines.json bench/results/freeloader.json
"""

import json
import sys
from pathlib import Path

ARM_NAMES = {"sonnet": "Sonnet alone", "opus": "Opus alone", "freeloader": "freeloader"}


def load(paths):
    runs = [json.loads(Path(p).read_text()) for p in paths]
    results = [r for run in runs for r in run["results"]]
    return runs, results


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(lines)


def minutes(seconds):
    return f"{seconds // 60}m {seconds % 60:02d}s"


def main():
    runs, results = load(sys.argv[1:])
    arms = [a for a in ARM_NAMES if any(r["arm"] == a for r in results)]
    tasks = sorted({r["task"] for r in results})
    cell = {(r["arm"], r["task"]): r for r in results}

    print("### Correctness: hidden tests passed\n")
    print(table(["Task"] + [ARM_NAMES[a] for a in arms], [
        [task] + [f"{cell[a, task]['hidden_passed']}/{cell[a, task]['hidden_total']}" for a in arms]
        for task in tasks
    ]))

    print("\n### Claude cost per task (USD)\n")
    print(table(["Task"] + [ARM_NAMES[a] for a in arms], [
        [task] + [f"{cell[a, task]['cost_usd']:.2f}" for a in arms] for task in tasks
    ]))

    print("\n### Wall time per task\n")
    print(table(["Task"] + [ARM_NAMES[a] for a in arms], [
        [task] + [minutes(cell[a, task]["seconds"]) for a in arms] for task in tasks
    ]))

    print("\n### Totals\n")
    rows = []
    for arm in arms:
        mine = [cell[arm, t] for t in tasks]
        rows.append([
            ARM_NAMES[arm],
            f"{sum(r['solved'] for r in mine)}/{len(mine)}",
            f"{sum(r['hidden_passed'] for r in mine)}/{sum(r['hidden_total'] for r in mine)}",
            f"{sum(r['original_passed'] for r in mine)}/{sum(r['original_total'] for r in mine)}",
            f"{sum(r['cost_usd'] for r in mine):.2f}",
            minutes(sum(r["seconds"] for r in mine)),
        ])
    print(table(["Arm", "Tasks fully solved", "Hidden tests", "Existing tests", "Claude cost", "Wall time"], rows))

    if "freeloader" in arms:
        print("\n### Inside the freeloader runs\n")
        rows = []
        for task in tasks:
            r = cell["freeloader", task]
            d = r.get("freeloader", {})
            by_model = r.get("cost_by_model", {})
            opus = sum(v for k, v in by_model.items() if "opus" in k)
            sonnet = sum(v for k, v in by_model.items() if "sonnet" in k)
            attempts = sum(m["attempts"] for m in d.get("models", {}).values())
            rows.append([task, d.get("planned_tasks", 0), d.get("tasks_passed_free", 0),
                         d.get("tasks_escalated", 0), d.get("tasks_not_passed", 0), attempts,
                         f"{opus:.2f}", f"{sonnet:.2f}"])
        print(table(["Task", "Subtasks planned", "Passed on free models", "Escalated to Sonnet",
                     "Not passed", "Free-model attempts", "Opus cost", "Sonnet cost"], rows))

        models = {}
        for task in tasks:
            for name, m in cell["freeloader", task].get("freeloader", {}).get("models", {}).items():
                total = models.setdefault(name, {"attempts": 0, "passes": 0, "quota": 0, "refused": 0})
                for key in total:
                    total[key] += m.get(key, 0)
        if models:
            print("\n### Free models\n")
            print(table(["Model", "Attempts", "Passes", "Rate limited", "Refused"], [
                [name, m["attempts"], m["passes"], m["quota"], m["refused"]]
                for name, m in sorted(models.items(), key=lambda kv: -kv[1]["attempts"])
            ]))

    print("\nRun on " + ", ".join(sorted({run["date"] for run in runs}))
          + " with " + ", ".join(sorted({run["claude_code"] for run in runs}))
          + f", freeloader at commit {runs[-1]['freeloader_commit']}.")


if __name__ == "__main__":
    main()
