# Changelog

Notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-05

First public version.

### Added

- `/freeloader:build`: an Opus architect plans a feature as small task files, free opencode models implement them, and Opus reviews the combined diff.
- Task runner with one git worktree per attempt, a file-scope check, an acceptance gate, and a reviewer model, with feedback rounds and a model fallback chain.
- Racing: one to three models work on the same task at once, depending on its tier, and the first to pass wins.
- Acceptance tests written by the architect and protected from the coder.
- Plan check for missing acceptance commands, unknown or circular dependencies, and parallel tasks that would edit the same file.
- Rate-limit cooldown, so a model that returns a 429 is skipped for a while.
- Run ledger, `/freeloader:stats`, and model ordering by recorded pass rate.
- `/freeloader:resume` for interrupted builds, and cached results for tasks that already passed.
- Pull request hand-off through the `gh` CLI.
- `/freeloader:doctor` preflight.
- End-to-end test suite that runs without model access.

[0.2.0]: https://github.com/mobashirrahman/freeloader/releases/tag/v0.2.0
