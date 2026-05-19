# Personal Agent Manager — Basic Symphony Dashboard Setup

## Goal

Get the cloned `openai/symphony` Elixir dashboard running locally, then adapt it into a personal agent manager that uses:

- Cursor IDE for larger coding work
- Qwen3:8b via Ollama for local task parsing/summarizing
- Symphony as the Elixir/Phoenix orchestration + dashboard base
- No Linear dependency long-term

Target architecture:

```text
Phone browser
  -> Phoenix/Symphony dashboard
  -> Local task database
  -> Agent runner
  -> Qwen3 / Cursor / Codex workers
```

## Current folder assumptions

```text
C:\GitHub\symphony
C:\GitHub\symphony\elixir
```

Elixir and Erlang should resolve from:

```text
E:\Elixir\bin
E:\Erlang OTP\bin
```

Verify:

```powershell
where.exe erl
where.exe elixir
where.exe mix

erl -eval "erlang:display(erlang:system_info(otp_release)), halt()." -noshell
elixir --version
mix --version
```

Expected: `erl`, `elixir`, and `mix` should point to the E: installs, not Chocolatey or `C:\Program Files`.

## First milestone: run the existing Symphony dashboard

From PowerShell:

```powershell
cd C:\GitHub\symphony\elixir
mix deps.get
mix compile
```

Then start Symphony with the dashboard enabled:

```powershell
.\bin\symphony .\WORKFLOW.md --port 4321
```

Open:

```text
http://localhost:4321
```

For phone access on the same network, find your machine IP:

```powershell
ipconfig
```

Then visit from phone:

```text
http://YOUR_PC_LAN_IP:4321
```

Example:

```text
http://192.168.1.25:4321
```

If Windows Firewall prompts, allow access on private networks.

## Important: we do not want Linear

The cloned Symphony implementation starts from a Linear-based workflow. For this personal system, Linear should be replaced with a local task source.

Do not build around:

```text
Phone -> Linear -> Symphony -> Agent
```

Build toward:

```text
Phone -> Symphony/Phoenix -> Local SQLite tasks -> Agent runner
```

## Planned code change

Replace or bypass the Linear tracker with a local tracker module.

Create a local task source that returns task records in the same shape the orchestrator currently expects from tracker issues.

Suggested module names:

```text
Symphony.Tracker.Local
Symphony.Tasks
Symphony.Tasks.Task
Symphony.Tasks.TaskEvent
Symphony.AgentRuns.AgentRun
```

Suggested local statuses:

```text
queued
assigned
running
waiting
blocked
done
failed
cancelled
```

## Minimal local database schema

Use SQLite first.

Tables:

```text
tasks
  id
  title
  body
  status
  priority
  assigned_agent
  workspace_path
  result
  inserted_at
  updated_at

task_events
  id
  task_id
  kind
  message
  metadata
  inserted_at

agent_runs
  id
  task_id
  agent_name
  status
  started_at
  finished_at
  result
```

## Mobile dashboard routes

Add or adapt Phoenix LiveView routes:

```text
/                  dashboard
/tasks/new         create task
/tasks/:id         task detail, logs, result
/agents            agent status
/settings          local settings
/auth?token=...    one-time phone login
```

## Auth requirement

Use a query token only for login:

```text
http://YOUR_PC_LAN_IP:4321/auth?token=SECRET
```

After validation, redirect to:

```text
/
```

Do not keep the token in the URL.

Environment variable:

```powershell
[Environment]::SetEnvironmentVariable("AGENT_MANAGER_TOKEN", "replace-with-long-random-token", "User")
$env:AGENT_MANAGER_TOKEN = "replace-with-long-random-token"
```

## Qwen3:8b role

Qwen3 runs locally through Ollama and should be the default lightweight brain.

Use it for:

```text
- turning phone notes into structured tasks
- summarizing agent logs
- classifying task difficulty
- explaining errors
- writing small prompts
- reviewing small diffs
```

Do not rely on it alone for large repo-wide coding changes.

Local Ollama check:

```powershell
ollama list
ollama run qwen3:8b
```

Future Elixir integration should call Ollama at:

```text
http://localhost:11434/api/chat
```

## Cursor role

Cursor is the larger coding assistant.

Initial workflow:

```text
1. Create task in dashboard
2. Qwen3 summarizes/plans it
3. Open task/workspace in Cursor
4. Let Cursor implement larger code changes
5. Symphony dashboard tracks status/result
```

Later workflow:

```text
Symphony -> isolated workspace -> Cursor CLI/headless agent -> logs/result -> dashboard
```

Do not automate the Cursor GUI with clicks/keystrokes. Prefer CLI/headless/API integration when available.

Check local Cursor commands:

```powershell
where.exe cursor
where.exe cursor-agent
cursor --help
cursor-agent --help
```

## First implementation checklist

1. Get existing Symphony Elixir project compiling.
2. Start dashboard with `--port 4321`.
3. Confirm phone can reach dashboard over LAN.
4. Add phone token auth plug.
5. Add SQLite/Ecto task tables.
6. Add `Symphony.Tracker.Local`.
7. Make dashboard show local tasks instead of Linear issues.
8. Add “New Task” LiveView form.
9. Add Qwen3/Ollama summarizer endpoint.
10. Add Cursor handoff instructions or CLI runner.

## Definition of done for MVP

The MVP is working when I can:

```text
- open dashboard from my phone
- authenticate with my private token
- create a task
- see it in queued/running/done states
- view logs/events
- ask Qwen3 to summarize status
- manually open the task/workspace in Cursor
```

Do not worry about full autonomous Cursor jobs until the local dashboard and task database are stable.
