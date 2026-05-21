---
tracker:
  kind: local
  database_path: ./data/symphony_tasks.db
  active_states:
    - running
  terminal_states:
    - review
    - done
    - failed
    - cancelled
    - queued
    - assigned
    - waiting
    - blocked
polling:
  interval_ms: 5000
server:
  host: 127.0.0.1
  port: 4321
workspace:
  root: C:/GitHub/symphony
  seed_mode: copy
  seed_path: C:/GitHub/symphony
agent:
  max_concurrent_agents: 1
  max_turns: 20
---

You are working on task `{{ issue.identifier }}` for a **solo developer** using Symphony as a personal agent queue (not a team Linear workflow).

## Issue

- **ID:** {{ issue.identifier }}
- **Title:** {{ issue.title }}
- **Status:** {{ issue.state }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Your job

1. Read `SYMPHONY_TASK.md` in the workspace when present (plan and any task-specific notes).
2. Implement the task autonomously. Do not ask the human to do follow-up steps.
3. Work in the **main project repository** at `C:/GitHub/symphony` (or the task's `project_path` when set). Do **not** create or use an isolated per-task workspace copy.
4. When finished, leave your changes in the working tree. The human handles git (branch, commit, push).

## Workspace

- Use the existing checkout — Symphony should dispatch with **linked** workspace mode on this repo, not an isolated `TASK-N` copy under `~/code/symphony-workspaces`.
- Do not seed, clone, or copy the repo into a new folder for this task.

## Git

- Stay on the **current branch** (`git branch --show-current`). Do not create `symphony/*` branches or switch branches unless the task explicitly says otherwise.
- Do **not** commit, push, or open pull requests — the human handles all git operations manually.
- Ignore any **Queue git batch** section in `SYMPHONY_TASK.md` unless the task body explicitly overrides these rules.

## Quality

- Reproduce or confirm current behavior before changing code.
- Run targeted validation for what you changed.
- Do not leave secrets, build artifacts, or unrelated files in the tree.

## Handoff

Symphony marks the task **review** (not **done**) when headless `cursor-agent` exits successfully. The human reviews on the Reviews screen and marks **done** when satisfied — you do not need to write a long summary comment.

If truly blocked (missing auth/tooling), log the blocker in the task log and stop; do not invent workarounds that leave the repo in a worse state.
