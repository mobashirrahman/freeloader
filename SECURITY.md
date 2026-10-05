# Security

## What you should know before running this

freeloader runs third-party models unattended, with shell access, against your code. The design limits what they can do, but it does not sandbox them.

- Coders work in a separate git worktree and are denied writes outside it and a list of shell commands (`git push`, `curl`, `ssh`, `sudo`, and others). These rules are enforced by opencode's permission system.
- Coders and reviewers may fetch web pages by default, so that they can read documentation. A fetched page is untrusted text given to an agent that has a shell. The prompts tell the models not to follow instructions found in pages, which lowers the risk without removing it. Set `coder.web` and `reviewer.web` to `false` to turn fetching off.
- The shell deny list matches command prefixes. A determined or confused model can get around it, for example by wrapping a command in `bash -c`. Treat it as a guardrail against accidents, not as containment.
- Your code is sent to whichever model providers you configure. Free tiers often log or train on what they receive.

- If you turn on egress proxies, the proxy credentials are kept out of the agents' environment and out of every log, but the file holding them is still on a disk that the coder's shell can read.

If any of these matter for your situation, run freeloader inside a container or VM, and keep it away from repositories and machines that hold secrets.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting instead: on this repository, go to **Security**, then **Report a vulnerability**. I will reply as soon as I can.
