# Changelog

Notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-10-05

### Changed

- The coder and reviewer now run on opencode's stock `build` agent with a per-run permission config. opencode's free tier began refusing requests that used freeloader's custom agents, and custom agents are widely reported not to work on it.
- Coders and reviewers may fetch web pages, so they can read documentation. `coder.web` and `reviewer.web` turn this off.
- A model that refuses a request is skipped for the cooldown period, the same as one that is rate-limited.
- Reviewer models that are cooling down are not asked. The task is then merged on the acceptance gate alone, unless `reviewer.required` is set.
- `/freeloader:doctor --ping` tests each model in the role it will be used for and shows the provider's reason when one fails.

### Added

- `opencode` is on the coder's shell deny list, so a coder cannot start agents of its own.

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

[0.3.0]: https://github.com/mobashirrahman/freeloader/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mobashirrahman/freeloader/releases/tag/v0.2.0
