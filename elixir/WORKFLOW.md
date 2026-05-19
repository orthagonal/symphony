---
tracker:
  kind: local
  database_path: ./data/symphony_tasks.db
  active_states:
    - running
  terminal_states:
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
  root: ~/code/symphony-workspaces
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

1. Read `SYMPHONY_TASK.md` in the workspace (plan, git rules, queue batch info).
2. Implement the task autonomously. Do not ask the human to do follow-up steps.
3. Work only inside the assigned workspace / project folder.
4. When finished, ensure the workspace is **pristine** (clean working tree on the expected branch) unless the task says otherwise.

## Git (when `git rev-parse --is-inside-work-tree` works)

Follow the **Queue git batch** section in `SYMPHONY_TASK.md` when present.

Otherwise:

1. Save `ORIGINAL_BRANCH=$(git branch --show-current)`.
2. Create and use branch `symphony/{{ issue.identifier }}-<short-slug>`.
3. Commit **only** this task's generated/changed code and READMEs (no secrets, build artifacts, or unrelated files).
4. `git switch "$ORIGINAL_BRANCH"` when done.

**Same repo, multiple queued tasks:** consecutive tasks sharing a project folder use one shared branch; each task gets its own commit message including the task id and title; only the **last** task in the batch restores `ORIGINAL_BRANCH`.

## Quality

- Reproduce or confirm current behavior before changing code.
- Run targeted validation for what you changed.
- Keep commits focused; stage paths deliberately.

## Handoff

Symphony marks the task **done** when headless `cursor-agent` exits successfully. A **review ticket** is then created for the human — you do not need to write a long summary comment.

If truly blocked (missing auth/tooling), log the blocker in the task log and stop; do not invent workarounds that leave the repo dirty.
