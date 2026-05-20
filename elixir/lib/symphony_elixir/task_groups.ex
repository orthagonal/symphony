defmodule SymphonyElixir.TaskGroups do
  @moduledoc """
  Task groups: a parent description decomposed into child tasks via Ollama.

  Child tasks are local-only (Ollama) when `local_only: true` is passed; otherwise they
  use Cursor/cursor-agent like ordinary tasks.
  """

  import Ecto.Query

  alias SymphonyElixir.{Ollama, Repo, Tasks}
  alias SymphonyElixir.TaskGroups.TaskGroup
  alias SymphonyElixir.Tasks.Task

  @spec list_all() :: [TaskGroup.t()]
  def list_all do
    from(g in TaskGroup, order_by: [desc: g.inserted_at])
    |> Repo.all()
  end

  @spec get!(integer()) :: TaskGroup.t()
  def get!(id) when is_integer(id), do: Repo.get!(TaskGroup, id)

  @spec get_with_tasks!(integer()) :: TaskGroup.t()
  def get_with_tasks!(id) when is_integer(id) do
    TaskGroup
    |> Repo.get!(id)
    |> Repo.preload(tasks: from(t in Task, order_by: [asc: t.priority, asc: t.inserted_at]))
  end

  @spec task_counts() :: %{integer() => integer()}
  def task_counts do
    from(t in Task,
      where: not is_nil(t.task_group_id),
      group_by: t.task_group_id,
      select: {t.task_group_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @spec create(map()) :: {:ok, TaskGroup.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %TaskGroup{}
    |> TaskGroup.changeset(attrs)
    |> Repo.insert()
  end

  @spec generate_from_description(String.t(), keyword()) ::
          {:ok, TaskGroup.t(), [Task.t()]} | {:error, term()}
  def generate_from_description(description, opts \\ []) when is_binary(description) do
    title = Keyword.get(opts, :title) || default_group_title(description)
    project_path = Keyword.get(opts, :project_path)
    workspace_mode = Keyword.get(opts, :workspace_mode, "isolated")
    priority = Keyword.get(opts, :priority, 3)
    local_only = Keyword.get(opts, :local_only, false)
    assigned_agent = Keyword.get(opts, :assigned_agent)

    with {:ok, chunks} <- Ollama.decompose_task_group(description),
         {:ok, group} <- create(%{title: title, description: description, status: "active"}),
         {:ok, tasks} <-
           insert_child_tasks(group, chunks,
             project_path: project_path,
             workspace_mode: workspace_mode,
             priority: priority,
             local_only: local_only,
             assigned_agent: assigned_agent
           ) do
      {:ok, group, tasks}
    end
  end

  @spec local_only_group_ids() :: MapSet.t(integer())
  def local_only_group_ids do
    from(t in Task,
      where: not is_nil(t.task_group_id),
      select: {t.task_group_id, t.local_only}
    )
    |> Repo.all()
    |> Enum.group_by(fn {gid, _} -> gid end, fn {_, local?} -> local? end)
    |> Enum.filter(fn {_gid, flags} ->
      flags != [] and Enum.all?(flags, & &1)
    end)
    |> Enum.map(fn {gid, _} -> gid end)
    |> MapSet.new()
  end

  defp insert_child_tasks(group, chunks, opts) do
    project_path = Keyword.get(opts, :project_path)
    workspace_mode = Keyword.get(opts, :workspace_mode, "isolated")
    priority = Keyword.get(opts, :priority, 3)
    local_only = Keyword.get(opts, :local_only, false)
    assigned_agent = Keyword.get(opts, :assigned_agent)

    tasks =
      Enum.map(chunks, fn chunk ->
        attrs =
          %{
            "title" => chunk.title,
            "body" => chunk.body,
            "status" => "queued",
            "priority" => priority,
            "task_group_id" => group.id,
            "local_only" => local_only,
            "workspace_mode" => workspace_mode
          }
          |> put_assigned_agent(local_only, assigned_agent)

        attrs =
          if is_binary(project_path) and project_path != "" do
            Map.put(attrs, "project_path", project_path)
          else
            attrs
          end

        case Tasks.create(attrs) do
          {:ok, task} ->
            _ = Tasks.log_event!(task.id, "task_group", "Added to overnight group ##{group.id}")
            task

          {:error, changeset} ->
            raise "failed to create group task: #{inspect(changeset.errors)}"
        end
      end)

    {:ok, tasks}
  end

  @spec update_all_tasks_status!(integer(), String.t()) :: TaskGroup.t()
  def update_all_tasks_status!(group_id, status) when is_integer(group_id) and is_binary(status) do
    group = get_with_tasks!(group_id)

    Enum.each(group.tasks, fn task ->
      _ = Tasks.update_status!(task.id, status)
      _ = Tasks.log_event!(task.id, "status", "Group bulk update → #{status} (GROUP-#{group_id})")
    end)

    get_with_tasks!(group_id)
  end

  @spec delete_group!(integer()) :: :ok
  def delete_group!(group_id) when is_integer(group_id) do
    group = get_with_tasks!(group_id)

    Enum.each(group.tasks, fn task ->
      _ = Tasks.delete!(task.id)
    end)

    Repo.delete!(group)
    :ok
  end

  defp put_assigned_agent(attrs, true, agent) do
    Map.put(attrs, "assigned_agent", agent || "ollama")
  end

  defp put_assigned_agent(attrs, false, agent) when is_binary(agent) and agent != "" do
    Map.put(attrs, "assigned_agent", agent)
  end

  defp put_assigned_agent(attrs, false, _) do
    Map.put(attrs, "assigned_agent", "cursor")
  end

  defp default_group_title(description) do
    description
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 80)
    |> case do
      "" -> "Overnight task group"
      line -> line
    end
  end
end
