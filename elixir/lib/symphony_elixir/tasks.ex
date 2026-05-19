defmodule SymphonyElixir.Tasks do
  @moduledoc """
  Local SQLite-backed task store for the `local` tracker adapter.
  """

  import Ecto.Query

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Tasks.{Task, TaskEvent}

  @reviews_pubsub_topic "reviews"

  @default_db_name "symphony_tasks.db"

  @spec database_path() :: Path.t()
  def database_path do
    case Application.get_env(:symphony_elixir, :tasks_database_path) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        workflow_database_path() || env_database_path() || default_database_path()
    end
  end

  @spec configure_repo!() :: :ok
  def configure_repo! do
    path = database_path()
    File.mkdir_p!(Path.dirname(path))

    Application.put_env(:symphony_elixir, SymphonyElixir.Repo,
      database: path,
      pool_size: 5,
      busy_timeout: 10_000
    )

    :ok
  end

  @spec migrate() :: :ok
  def migrate do
    configure_repo!()

    if Process.whereis(Repo) do
      migrate_up!()
    else
      {:ok, _, _} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, migrator_run_opts())
        end)

      :ok
    end
  end

  @spec migrate_up!() :: :ok
  def migrate_up! do
    case Process.whereis(Repo) do
      pid when is_pid(pid) ->
        Ecto.Migrator.run(Repo, :up, migrator_run_opts())
        :ok

      _ ->
        raise "SymphonyElixir.Repo is not running; cannot run database migrations"
    end
  end

  defp migrator_run_opts do
    [all: true] ++ migrator_opts()
  end

  defp migrator_opts do
    case Application.get_env(:symphony_elixir, :migrations_path) do
      path when is_binary(path) and path != "" ->
        [migrations_path: path]

      _ ->
        case :code.priv_dir(:symphony_elixir) do
          priv when is_binary(priv) ->
            [migrations_path: Path.join(priv, "repo/migrations")]

          _ ->
            []
        end
    end
  end

  @spec list_all() :: [Task.t()]
  def list_all do
    from(t in Task, order_by: [asc: t.priority, desc: t.inserted_at])
    |> Repo.all()
  end

  @spec list_queued() :: [Task.t()]
  def list_queued do
    from(t in Task,
      where: t.status == "queued",
      order_by: [asc: t.priority, asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @spec list_in_review() :: [Task.t()]
  def list_in_review do
    from(t in Task,
      where: t.status == "review",
      order_by: [desc: t.updated_at],
      preload: [:review_ticket]
    )
    |> Repo.all()
  end

  @spec get_with_events!(integer()) :: Task.t()
  def get_with_events!(id) when is_integer(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload(events: from(e in TaskEvent, order_by: [desc: e.inserted_at], limit: 200))
  end

  @spec list_events(integer()) :: [TaskEvent.t()]
  def list_events(task_id) when is_integer(task_id) do
    from(e in TaskEvent,
      where: e.task_id == ^task_id,
      order_by: [desc: e.inserted_at],
      limit: 200
    )
    |> Repo.all()
  end

  @spec update!(integer(), map()) :: Task.t()
  def update!(task_id, attrs) when is_integer(task_id) and is_map(attrs) do
    task = Repo.get!(Task, task_id)

    task
    |> Task.changeset(attrs)
    |> Repo.update!()
  end

  @spec delete!(integer()) :: Task.t()
  def delete!(task_id) when is_integer(task_id) do
    task = Repo.get!(Task, task_id)

    SymphonyElixir.TaskQueue.ack_task_removed(task_id)
    Repo.delete!(task)

    task
  end

  @spec log_event!(integer(), String.t(), String.t(), map() | nil) :: TaskEvent.t()
  def log_event!(task_id, kind, message, metadata \\ nil)
      when is_integer(task_id) and is_binary(kind) and is_binary(message) do
    attrs = %{task_id: task_id, kind: kind, message: message}

    attrs =
      if is_map(metadata) do
        Map.put(attrs, :metadata, metadata)
      else
        attrs
      end

    %TaskEvent{}
    |> TaskEvent.changeset(attrs)
    |> Repo.insert!()
  end

  @spec counts_by_status() :: %{String.t() => integer()}
  def counts_by_status do
    from(t in Task, group_by: t.status, select: {t.status, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @spec create(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "queued")

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @spec get!(integer()) :: Task.t()
  def get!(id), do: Repo.get!(Task, id)

  @spec list_issues_in_states([String.t()]) :: [Issue.t()]
  def list_issues_in_states(state_names) when is_list(state_names) do
    normalized =
      state_names
      |> Enum.map(&normalize_status/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if normalized == [] do
      []
    else
      from(t in Task, where: t.status in ^normalized, order_by: [asc: t.priority, asc: t.inserted_at])
      |> Repo.all()
      |> Enum.map(&to_issue/1)
    end
  end

  @spec list_issues_by_ids([String.t()]) :: [Issue.t()]
  def list_issues_by_ids(ids) when is_list(ids) do
    wanted =
      ids
      |> Enum.map(&parse_task_id/1)
      |> Enum.reject(&is_nil/1)

    if wanted == [] do
      []
    else
      from(t in Task, where: t.id in ^wanted)
      |> Repo.all()
      |> Enum.map(&to_issue/1)
    end
  end

  @spec update_status!(integer(), String.t()) :: Task.t()
  def update_status!(task_id, status_name) when is_integer(task_id) do
    status = normalize_status(status_name)

    task = Repo.get!(Task, task_id)

    updated =
      task
      |> Task.changeset(%{status: status})
      |> Repo.update!()

    if status == "review" do
      SymphonyElixir.Reviews.create_for_completed_task!(updated)
    end

    if status in ["done", "failed", "cancelled", "review"] do
      SymphonyElixir.TaskQueue.notify_task_terminal(updated.id)
    end

    if status in ["review", "done", "failed", "queued", "cancelled"] do
      broadcast_review_ui(updated.id)
    end

    updated
  end

  @doc """
  Send a task back to the queue after human review: prepend reviewer notes and prior
  review ticket context to the task body, delete the review ticket row, set status `queued`.
  """
  @spec resubmit_from_review!(integer(), String.t()) :: Task.t()
  def resubmit_from_review!(task_id, notes) when is_integer(task_id) and is_binary(notes) do
    task = Repo.get!(Task, task_id)

    if task.status != "review" do
      raise ArgumentError, "task #{task_id} is not in review (status=#{task.status})"
    end

    ticket = Repo.get_by(SymphonyElixir.Reviews.ReviewTicket, task_id: task_id)
    block = resubmit_preamble_block(ticket, notes)

    SymphonyElixir.Reviews.delete_tickets_for_task!(task_id)

    new_body =
      case String.trim(block) do
        "" -> task.body || ""
        trimmed -> trimmed <> "\n\n---\n\n" <> (task.body || "")
      end

    updated =
      task
      |> Task.changeset(%{body: new_body, status: "queued"})
      |> Repo.update!()

    _ =
      log_event!(
        task_id,
        "resubmit",
        "Returned to queue with reviewer feedback (#{String.length(notes)} chars)"
      )

    broadcast_review_ui(task_id)
    updated
  end

  @spec add_comment!(integer(), String.t()) :: TaskEvent.t()
  def add_comment!(task_id, body) when is_integer(task_id) and is_binary(body) do
    %TaskEvent{}
    |> TaskEvent.changeset(%{task_id: task_id, kind: "comment", message: body})
    |> Repo.insert!()
  end

  @spec to_issue(Task.t()) :: Issue.t()
  def to_issue(%Task{} = task) do
    task_id = Integer.to_string(task.id)

    %Issue{
      id: task_id,
      identifier: identifier_for(task),
      title: task.title,
      description: task.body,
      priority: task.priority,
      state: task.status,
      branch_name: nil,
      url: task_url(task),
      assignee_id: task.assigned_agent,
      blocked_by: [],
      labels: [],
      assigned_to_worker: assigned_to_worker?(task),
      created_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp workflow_database_path do
    with {:ok, settings} <- Config.settings(),
         path when is_binary(path) and path != "" <- settings.tracker.database_path do
      Path.expand(path)
    else
      _ -> nil
    end
  end

  defp env_database_path do
    case System.get_env("SYMPHONY_DATABASE_PATH") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp default_database_path do
    Path.expand(Path.join([File.cwd!(), "data", @default_db_name]))
  end

  defp identifier_for(%Task{id: id}), do: "TASK-#{id}"

  defp task_url(%Task{id: id}) do
    case dashboard_base_url() do
      nil -> nil
      base -> base <> "tasks/#{id}"
    end
  end

  @spec api_status_url(integer()) :: String.t() | nil
  def api_status_url(task_id) when is_integer(task_id) do
    case dashboard_base_url() do
      nil -> nil
      base -> base <> "api/v1/tasks/#{task_id}/status"
    end
  end

  defp dashboard_base_url do
    with host when is_binary(host) <- Config.settings!().server.host,
         port when is_integer(port) and port > 0 <- Config.server_port() do
      "http://#{dashboard_host(host)}:#{port}/"
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp dashboard_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"
  defp dashboard_host(host), do: host

  defp assigned_to_worker?(%Task{assigned_agent: nil}), do: true
  defp assigned_to_worker?(%Task{assigned_agent: ""}), do: true

  defp assigned_to_worker?(%Task{assigned_agent: assigned_agent}) when is_binary(assigned_agent) do
    case Config.settings() do
      {:ok, settings} ->
        case settings.tracker.assignee do
          nil -> true
          "" -> true
          filter -> assigned_agent == filter
        end

      _ ->
        true
    end
  end

  defp parse_task_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_task_id(id) when is_integer(id), do: id
  defp parse_task_id(_), do: nil

  defp normalize_status(status) when is_binary(status) do
    status |> String.trim() |> String.downcase()
  end

  defp normalize_status(_), do: ""

  defp broadcast_review_ui(task_id) when is_integer(task_id) do
    Phoenix.PubSub.broadcast(
      SymphonyElixir.PubSub,
      @reviews_pubsub_topic,
      {:tasks_changed, task_id}
    )
  end

  defp resubmit_preamble_block(nil, notes) do
    """
    ## Re-submitted after review — notes from reviewer

    #{String.trim(notes)}
    """
    |> String.trim()
  end

  defp resubmit_preamble_block(%SymphonyElixir.Reviews.ReviewTicket{} = ticket, notes) do
    checklist_lines =
      (ticket.checklist || [])
      |> Enum.map(fn item ->
        mark = if item["done"], do: "[x]", else: "[ ]"
        "#{mark} #{item["label"]}"
      end)
      |> Enum.join("\n")

    checklist_lines =
      if checklist_lines == "", do: "_No checklist items._", else: checklist_lines

    summary =
      case ticket.summary do
        s when is_binary(s) and s != "" -> s
        _ -> "_No summary._"
      end

    """
    ## Re-submitted after review — notes from reviewer

    #{String.trim(notes)}

    ### Prior review ticket ('#{ticket.title}')

    **Summary:** #{summary}

    **Checklist:**
    #{checklist_lines}
    """
    |> String.trim()
  end
end
