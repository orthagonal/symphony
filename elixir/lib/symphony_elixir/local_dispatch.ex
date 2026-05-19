defmodule SymphonyElixir.LocalDispatch do
  @moduledoc """
  Runs local-only tasks via Ollama (no Cursor / cursor-agent).
  """

  require Logger

  alias SymphonyElixir.{Ollama, Tasks}
  alias SymphonyElixir.Cursor.WorkspaceBootstrap
  alias SymphonyElixir.Tasks.Task

  @max_log_chars 8_000

  @spec start_async(integer(), keyword()) :: :ok
  def start_async(task_id, opts \\ []) when is_integer(task_id) do
    Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      case run(task_id, opts) do
        {:ok, _task} ->
          :ok

        {:error, reason} ->
          Logger.error("LocalDispatch failed task_id=#{task_id} reason=#{inspect(reason)}")

          safe_log(
            task_id,
            "local_error",
            Exception.message(normalize_error(reason))
          )

          _ = Tasks.update_status!(task_id, "review")
      end
    end)

    :ok
  end

  @spec run(integer(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def run(task_id, opts \\ []) when is_integer(task_id) do
    git_batch = Keyword.get(opts, :git_batch)
    task = Tasks.get_with_events!(task_id)
    safe_log(task.id, "local_dispatch", "Local-only dispatch started (Ollama #{Ollama.model()})")

    with {:ok, workspace} <- ensure_workspace(task, git_batch),
         {:ok, task} <- {:ok, Tasks.update!(task.id, %{workspace_path: workspace})},
         {:ok, implementation} <-
           Ollama.implement_task(Map.merge(task_payload(task), %{workspace_path: workspace})),
         {:ok, task} <- persist_result(task, implementation) do
      _ = Tasks.log_event!(task.id, "local_done", "Ollama implementation logged — marked review")
      {:ok, Tasks.update_status!(task.id, "review")}
    end
  end

  defp ensure_workspace(task, git_batch) do
    identifier = "TASK-#{task.id}"
    root = workspace_root(task, identifier)
    bootstrap_opts = if git_batch, do: [git_batch: git_batch], else: []
    WorkspaceBootstrap.bootstrap(root, task, bootstrap_opts)
  end

  defp workspace_root(%Task{workspace_mode: "linked", project_path: path}, _identifier)
       when is_binary(path) and path != "" do
    {:ok, Path.expand(path)}
  end

  defp workspace_root(%Task{workspace_path: path}, _identifier)
       when is_binary(path) and path != "" do
    {:ok, Path.expand(path)}
  end

  defp workspace_root(_task, identifier) do
    SymphonyElixir.Workspace.create_for_issue(identifier)
  end

  defp persist_result(task, implementation) when is_binary(implementation) do
    truncated =
      if String.length(implementation) > 50_000 do
        String.slice(implementation, 0, 50_000) <> "\n\n…(truncated)"
      else
        implementation
      end

    safe_log(task.id, "local_impl", truncate_log(truncated))
    {:ok, Tasks.update!(task.id, %{result: truncated, assigned_agent: "ollama"})}
  end

  defp task_payload(%Task{} = task) do
    %{
      title: task.title,
      body: task.body,
      status: task.status,
      project_path: task.project_path,
      workspace_path: task.workspace_path
    }
  end

  defp safe_log(task_id, kind, message) do
    Tasks.log_event!(task_id, kind, truncate_log(message))
  rescue
    error -> Logger.warning("log_event failed: #{inspect(error)}")
  end

  defp truncate_log(message) when is_binary(message) do
    if String.length(message) > @max_log_chars do
      String.slice(message, 0, @max_log_chars) <> "…"
    else
      message
    end
  end

  defp normalize_error(%{__struct__: _} = err), do: err
  defp normalize_error(reason), do: RuntimeError.exception(inspect(reason))
end
