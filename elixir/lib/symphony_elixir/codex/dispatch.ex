defmodule SymphonyElixir.Codex.Dispatch do
  @moduledoc """
  Dashboard task dispatch via local Codex app-server (stdio JSON-RPC).
  """

  require Logger

  alias SymphonyElixir.{Codex.AppServer, Ollama, Tasks}
  alias SymphonyElixir.Cursor.{Dispatch, WorkspaceBootstrap}
  alias SymphonyElixir.Tasks.Task

  @max_log_chars 8_000

  @spec start_async(integer(), keyword()) :: :ok
  def start_async(task_id, opts \\ []) when is_integer(task_id) do
    Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case run(task_id, opts) do
        {:ok, _task} ->
          :ok

        {:error, reason} ->
          Logger.error("Codex.Dispatch failed task_id=#{task_id} reason=#{inspect(reason)}")
          safe_log(task_id, "dispatch_error", Exception.message(normalize_error(reason)))
      end
    end)

    :ok
  end

  @spec run(integer(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def run(task_id, opts \\ []) when is_integer(task_id) do
    auto_plan? = Keyword.get(opts, :auto_plan, true)
    git_batch = Keyword.get(opts, :git_batch)
    task = Tasks.get_with_events!(task_id)

    safe_log(task.id, "dispatch", "Codex dispatch started")

    with {:ok, task} <- maybe_plan(task, auto_plan?),
         {:ok, workspace} <- ensure_workspace(task, git_batch),
         {:ok, task} <- {:ok, Tasks.update!(task.id, %{workspace_path: workspace, assigned_agent: "codex"})},
         :ok <- run_codex_agent(task, workspace) do
      {:ok, Tasks.get_with_events!(task.id)}
    end
  end

  defp run_codex_agent(task, workspace) do
    issue = Tasks.to_issue(task)
    prompt = Dispatch.build_agent_prompt(task, workspace, "TASK-#{task.id}")

    safe_log(task.id, "dispatch", "Starting Codex app-server in #{workspace}")

    Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case AppServer.run(workspace, prompt, issue) do
        {:ok, _result} ->
          safe_log(task.id, "agent_done", "Codex turn finished successfully")
          mark_review(task.id)

        {:error, reason} ->
          safe_log(task.id, "agent_failed", "Codex failed: #{inspect(reason)}")
      end
    end)

    Tasks.update_status!(task.id, "assigned")
    safe_log(task.id, "dispatch", "Codex running in background — watch Log")
    :ok
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

  defp ensure_workspace(task, git_batch) do
    identifier = "TASK-#{task.id}"
    bootstrap_opts = if git_batch, do: [git_batch: git_batch], else: []

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
    SymphonyElixir.Workspace.create_for_issue(identifier)
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

  defp mark_review(task_id) do
    task = Tasks.get!(task_id)

    if task.status in ["done", "failed", "cancelled", "review"] do
      :ok
    else
      Tasks.update_status!(task_id, "review")
      Tasks.log_event!(task_id, "status", "Marked review after Codex success")
    end
  rescue
    error ->
      Logger.warning("Codex mark_review failed: #{inspect(error)}")
      :ok
  end

  defp safe_log(task_id, kind, message) do
    Tasks.log_event!(task_id, kind, String.slice(message, 0, @max_log_chars))
  rescue
    _ -> :ok
  end

  defp normalize_error(%{__struct__: _} = err), do: err
  defp normalize_error(reason), do: RuntimeError.exception(inspect(reason))
end
