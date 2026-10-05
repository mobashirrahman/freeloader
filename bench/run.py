#!/usr/bin/env python3
"""Run the benchmark: the same requests through plain Claude Code and through freeloader.

    bench/run.py --arms sonnet,opus,freeloader --out bench/results/run.json

Each (arm, task) pair gets a fresh copy of bench/fixture as its own git repository
and one headless Claude Code session. Afterwards the task's hidden tests, which no
arm ever sees, are run against whatever the session produced.

Standard library only. Needs `claude`, `git`, and `pytest` on the PATH, and for the
freeloader arm everything freeloader itself needs.
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
FIXTURE = BENCH / "fixture"
TASKS = BENCH / "tasks"

BASELINE_TOOLS = "Bash,Read,Write,Edit,Glob,Grep"
FREELOADER_TOOLS = "Bash,Agent,Task,Read,Write,Edit,Glob,Grep"

BASELINE_SUFFIX = (
    "\n\nI am not at the keyboard, so do not ask questions. "
    "Work in this repository, finish the job, and stop."
)
FREELOADER_SUFFIX = (
    "\n\nI am not at the keyboard. I approve the plan in advance, so do not wait for "
    "confirmation at the checkpoint. At hand-over do not merge, do not open a pull "
    "request, and do not run cleanup; just report."
)

ARMS = {
    "sonnet": {"model": "sonnet", "freeloader": False},
    "opus": {"model": "opus", "freeloader": False},
    "freeloader": {"model": "sonnet", "freeloader": True},
}


def sh(args, cwd=None, env=None, timeout=None):
    return subprocess.run(args, cwd=cwd, env=env, timeout=timeout, capture_output=True, text=True)


def run_pytest(tree: Path, target: str) -> dict:
    """Run one test directory and return counts read from the junit report."""
    report = tree / f".{target}.xml"
    sh(
        [sys.executable, "-m", "pytest", target, "-q", "--tb=no", "-p", "no:cacheprovider",
         f"--junitxml={report}"],
        cwd=tree,
        timeout=300,
    )
    if not report.exists():
        return {"tests": 0, "passed": 0}
    suite = ET.parse(report).getroot()
    suite = suite if suite.tag == "testsuite" else suite.find("testsuite")
    tests = int(suite.get("tests", 0))
    bad = int(suite.get("failures", 0)) + int(suite.get("errors", 0)) + int(suite.get("skipped", 0))
    # A test module that fails to import is reported as one erroring test, so a
    # tree that does not import scores 0 without any special handling.
    return {"tests": tests, "passed": tests - bad}


def expected_counts() -> dict:
    """How many hidden tests each task has, taken from its reference solution."""
    counts = {}
    for task in sorted(TASKS.iterdir()):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "tree"
            shutil.copytree(FIXTURE, tree)
            shutil.copytree(task / "reference", tree, dirs_exist_ok=True)
            shutil.copytree(task / "hidden", tree / "tests_hidden")
            result = run_pytest(tree, "tests_hidden")
            if result["passed"] != result["tests"] or not result["tests"]:
                raise SystemExit(f"reference for {task.name} does not pass its hidden tests: {result}")
            counts[task.name] = result["tests"]
    return counts


def score(tree: Path, task: Path, total: int) -> dict:
    """Score a produced tree with the hidden tests and the fixture's original tests."""
    shutil.copytree(task / "hidden", tree / "tests_hidden", dirs_exist_ok=True)
    shutil.rmtree(tree / "tests_orig", ignore_errors=True)
    shutil.copytree(FIXTURE / "tests", tree / "tests_orig")
    hidden = run_pytest(tree, "tests_hidden")
    original = run_pytest(tree, "tests_orig")
    passed = min(hidden["passed"], total)
    return {
        "hidden_passed": passed,
        "hidden_total": total,
        "solved": passed == total,
        "original_passed": original["passed"],
        "original_total": original["tests"],
    }


def freeloader_details(repo: Path) -> dict:
    """What the free models did, read from freeloader's own records."""
    ledger = repo / ".freeloader" / "ledger.jsonl"
    rows = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.exists() else []
    attempts = [r for r in rows if r["kind"] == "attempt"]
    last = {}
    for row in rows:
        if row["kind"] == "task":
            last[row["id"]] = row
    by_model = {}
    for row in attempts:
        entry = by_model.setdefault(row["model"], {"attempts": 0, "passes": 0})
        if row["outcome"] in ("quota", "refused", "error"):
            entry[row["outcome"]] = entry.get(row["outcome"], 0) + 1
            continue
        entry["attempts"] += 1
        entry["passes"] += row["outcome"] == "pass"
    plans = list((repo / ".freeloader" / "plan").glob("*/*.md"))
    return {
        "planned_tasks": len(plans),
        "tasks_passed_free": sum(1 for r in last.values() if r["status"] == "pass" and r["model"] != "external"),
        "tasks_escalated": sum(1 for r in last.values() if r["status"] == "pass" and r["model"] == "external"),
        "tasks_not_passed": sum(1 for r in last.values() if r["status"] != "pass"),
        "free_model_seconds": sum(r.get("seconds", 0) for r in attempts),
        "models": by_model,
    }


def run_one(arm: str, task: Path, total: int, work: Path, raw: Path, timeout: int, plugin: Path) -> dict:
    spec = ARMS[arm]
    repo = work / arm / task.name / "repo"
    shutil.rmtree(repo.parent, ignore_errors=True)
    shutil.copytree(FIXTURE, repo)
    sh(["git", "init", "-q", "-b", "main"], cwd=repo)
    sh(["git", "add", "-A"], cwd=repo)
    sh(["git", "commit", "-q", "-m", "fixture"], cwd=repo)

    request = (task / "request.md").read_text().strip()
    command = ["claude", "--model", spec["model"], "--output-format", "json"]
    if spec["freeloader"]:
        command += ["--plugin-dir", str(plugin), "--allowedTools", FREELOADER_TOOLS,
                    "-p", "/freeloader:build " + request + FREELOADER_SUFFIX]
    else:
        command += ["--allowedTools", BASELINE_TOOLS, "-p", request + BASELINE_SUFFIX]

    # An empty config home keeps a developer's own freeloader settings out of the run.
    env = dict(os.environ, XDG_CONFIG_HOME=str(work / "xdg"))
    started = time.time()
    try:
        done = sh(command, cwd=repo, env=env, timeout=timeout)
        output, timed_out = done.stdout, False
    except subprocess.TimeoutExpired as expired:
        output, timed_out = (expired.stdout or b"").decode(errors="replace"), True
    seconds = round(time.time() - started)

    (raw / f"{arm}--{task.name}.json").write_text(output)
    try:
        session = json.loads(output)
    except json.JSONDecodeError:
        session = {}

    tree = work / arm / task.name / "tree"
    shutil.rmtree(tree, ignore_errors=True)
    branch = None
    if spec["freeloader"]:
        refs = sh(["git", "for-each-ref", "--format=%(refname:short)", "refs/heads/freeloader/*/main"],
                  cwd=repo).stdout.split()
        branch = refs[0] if refs else None
        tree.mkdir(parents=True)
        if branch:
            archive = subprocess.run(["git", "archive", branch], cwd=repo, capture_output=True)
            subprocess.run(["tar", "-x", "-C", str(tree)], input=archive.stdout)
        else:
            shutil.copytree(FIXTURE, tree, dirs_exist_ok=True)
    else:
        shutil.copytree(repo, tree, ignore=shutil.ignore_patterns(".git", ".freeloader", "__pycache__"))

    usage = session.get("modelUsage", {})
    result = {
        "arm": arm,
        "task": task.name,
        "seconds": seconds,
        "timed_out": timed_out,
        "session_error": bool(session.get("is_error", not session)),
        "cost_usd": round(session.get("total_cost_usd", 0.0), 4),
        "turns": session.get("num_turns"),
        "cost_by_model": {name: round(u.get("costUSD", 0.0), 4) for name, u in usage.items()},
        "output_tokens_by_model": {name: u.get("outputTokens", 0) for name, u in usage.items()},
        **score(tree, task, total),
    }
    if spec["freeloader"]:
        result["branch"] = branch
        result["freeloader"] = freeloader_details(repo)
    print(f"{arm:10} {task.name:14} {result['hidden_passed']:>3}/{total:<3} "
          f"${result['cost_usd']:.2f} {seconds:>5}s", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arms", default="sonnet,opus,freeloader")
    parser.add_argument("--tasks", default="all", help="comma-separated task names, or all")
    parser.add_argument("--out", required=True, help="where to write the results JSON")
    parser.add_argument("--work", help="working directory (default: a new temporary one)")
    parser.add_argument("--jobs", type=int, default=1, help="sessions to run at once")
    parser.add_argument("--timeout", type=int, default=2400, help="seconds allowed per session")
    parser.add_argument("--plugin-dir", default=str(ROOT),
                        help="freeloader checkout to test (default: this one)")
    args = parser.parse_args()

    arms = args.arms.split(",")
    tasks = sorted(TASKS.iterdir())
    if args.tasks != "all":
        tasks = [t for t in tasks if t.name in args.tasks.split(",")]
    totals = expected_counts()
    work = Path(args.work or tempfile.mkdtemp(prefix="freeloader-bench-")).resolve()
    (work / "xdg").mkdir(parents=True, exist_ok=True)
    out = Path(args.out).resolve()
    raw = out.parent / "raw" / out.stem
    raw.mkdir(parents=True, exist_ok=True)
    print(f"work directory: {work}", flush=True)

    pairs = [(arm, task) for arm in arms for task in tasks]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        plugin = Path(args.plugin_dir).resolve()
        futures = [pool.submit(run_one, arm, task, totals[task.name], work, raw, args.timeout, plugin)
                   for arm, task in pairs]
        results = [future.result() for future in futures]

    version = sh(["claude", "--version"]).stdout.strip()
    commit = sh(["git", "rev-parse", "--short", "HEAD"], cwd=args.plugin_dir).stdout.strip()
    out.write_text(json.dumps({
        "date": time.strftime("%Y-%m-%d"),
        "claude_code": version,
        "freeloader_commit": commit,
        "hidden_tests": totals,
        "results": results,
    }, indent=2) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
