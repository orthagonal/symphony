defmodule SymphonyElixir.Cursor.Dispatch do
  @moduledoc """
  End-to-end dispatch: Ollama plan → workspace seed → Cursor IDE → Cursor agent CLI.
  """

  require Logger

  alias SymphonyElixir.{Cursor, Ollama, Tasks, Workspace}
  alias SymphonyElixir.Cursor.WorkspaceBootstrap
  alias SymphonyElixir.Tasks.Task

  @max_prompt_chars 24_000
  @max_log_chars 8_000

  @spec start_async(integer(), keyword()) :: :ok
  def start_async(task_id, opts \\ []) when is_integer(task_id) do
    Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case run(task_id, opts) do
        {:ok, _task} ->
          :ok

        {:error, reason} ->
          Logger.error("Cursor.Dispatch failed task_id=#{task_id} reason=#{inspect(reason)}")
          safe_log(task_id, "dispatch_error", Exception.message(normalize_error(reason)))
      end
    end)

    :ok
  end

  @spec run(integer(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def run(task_id, opts \\ []) when is_integer(task_id) do
    auto_plan? = Keyword.get(opts, :auto_plan, true)
    open_ide? = Keyword.get(opts, :open_ide, false)
    run_agent? = Keyword.get(opts, :run_agent, true)
    git_batch = Keyword.get(opts, :git_batch)

    task = Tasks.get_with_events!(task_id)
    identifier = "TASK-#{task.id}"

    safe_log(task.id, "dispatch", "Dispatch started")

    with {:ok, task} <- maybe_plan(task, auto_plan?),
         {:ok, workspace} <- ensure_workspace(task, git_batch),
         {:ok, task} <- persist_workspace(task, workspace) do
      task = finalize_ide_and_agent(task, workspace, identifier, open_ide?, run_agent?)
      {:ok, task}
    end
  end

  defp finalize_ide_and_agent(task, workspace, identifier, open_ide?, run_agent?) do
    if open_ide? do
      case Cursor.open_workspace_file(workspace, identifier) do
        {:ok, _} ->
          safe_log(task.id, "dispatch", "Opened Cursor on #{identifier}.code-workspace")
          maybe_open_task_brief(workspace)

        {:error, :cursor_cli_not_found} ->
          safe_log(task.id, "dispatch", "Cursor CLI not found — open the workspace folder manually")

        {:error, reason} ->
          safe_log(task.id, "dispatch", "Cursor open failed: #{inspect(reason)}")
      end
    end

    if run_agent? do
      case Cursor.agent_executable() do
        nil ->
          safe_log(
            task.id,
            "dispatch",
            "cursor-agent not found. Install: irm https://cursor.com/install?win32=true | iex — or set CURSOR_AGENT_COMMAND"
          )

        agent_exe ->
          case Cursor.agent_authenticated?() do
            :ok ->
              safe_log(task.id, "dispatch", "Starting cursor-agent (#{agent_exe}) — may take several minutes")

              case Cursor.run_agent(agent_exe, workspace, "", task.id) do
                :ok ->
                  safe_log(task.id, "dispatch", "cursor-agent running in background")

                {:error, reason} ->
                  safe_log(task.id, "dispatch", "cursor-agent failed: #{inspect(reason)}")
              end

            {:error, auth_msg} ->
              safe_log(task.id, "agent_failed", auth_msg)

              safe_log(
                task.id,
                "dispatch",
                "Agent skipped (not logged in). Open SYMPHONY_TASK.md in Cursor → paste into Composer, or run: #{inspect(agent_exe)} login"
              )
          end
      end
    end

    Tasks.update_status!(task.id, "assigned")
    |> then(fn updated ->
      safe_log(updated.id, "dispatch", "Dispatch complete — check Log and Cursor window")
      Tasks.get_with_events!(updated.id)
    end)
  end

  defp maybe_plan(task, false), do: {:ok, task}

  defp maybe_plan(task, true) do
    if has_plan?(task) do
      {:ok, task}
    else
      safe_log(task.id, "dispatch", "Planning with Ollama (#{Ollama.model()})…")

      case Ollama.plan_task(task_payload(task)) do
        {:ok, plan} ->
          safe_log(task.id, "plan", plan)
          {:ok, Tasks.get_with_events!(task.id)}

        {:error, reason} ->
          {:error, {:plan_failed, reason}}
      end
    end
  end

  defp ensure_workspace(task, git_batch \\ nil) do
    task = Tasks.get_with_events!(task.id)
    identifier = "TASK-#{task.id}"

    safe_log(
      task.id,
      "dispatch",
      "Preparing workspace (#{task.workspace_mode}, project=#{task.project_path || "default"})…"
    )

    bootstrap_opts =
      if git_batch, do: [git_batch: git_batch], else: []

    with {:ok, path} <- workspace_root_for(task, identifier),
         {:ok, path} <- WorkspaceBootstrap.bootstrap(path, task, bootstrap_opts) do
      {:ok, path}
    end
  end

  defp workspace_root_for(%Task{workspace_mode: "linked", project_path: path}, _identifier)
       when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, {:project_path_not_found, expanded}}
    end
  end

  defp workspace_root_for(_task, identifier) do
    Workspace.create_for_issue(identifier)
  end

  defp persist_workspace(task, workspace) do
    {:ok, Tasks.update!(task.id, %{workspace_path: workspace})}
  end

  defp maybe_open_task_brief(workspace) do
    md = Path.join(workspace, "SYMPHONY_TASK.md")

    if File.exists?(md) do
      Cursor.open_folder(md)
    end
  end

  @spec build_agent_prompt(Task.t(), Path.t(), String.t()) :: String.t()
  def build_agent_prompt(%Task{} = task, workspace, identifier) do
    md_path = Path.join(workspace, "SYMPHONY_TASK.md")

    brief =
      if File.exists?(md_path) do
        File.read!(md_path)
      else
        """
        # #{identifier}: #{task.title}

        #{task.body || ""}
        """
      end

    brief = String.slice(brief, 0, @max_prompt_chars)

    """
    You are implementing Symphony task #{identifier} in this workspace.

    Treat the following as the full task brief (same as SYMPHONY_TASK.md). Implement the work in this repo copy only. When done, write a short summary of changes.

    --- TASK BRIEF ---
    #{brief}
    --- END BRIEF ---
    """
    |> String.trim()
  end

  defp has_plan?(%Task{events: events}) when is_list(events) do
    Enum.any?(events, &(&1.kind in ["plan", "llm_plan"]))
  end

  defp has_plan?(_), do: false

  defp task_payload(task) do
    %{
      title: task.title,
      body: task.body,
      status: task.status,
      events: task.events || []
    }
  end

  defp safe_log(task_id, kind, message) do
    Tasks.log_event!(task_id, kind, String.slice(message, 0, @max_log_chars))
  rescue
    error -> Logger.warning("dispatch log_event failed: #{inspect(error)}")
  end

  defp normalize_error(%{__struct__: _} = err), do: err
  defp normalize_error(reason), do: RuntimeError.exception(inspect(reason))
end
