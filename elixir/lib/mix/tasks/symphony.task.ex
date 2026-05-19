defmodule Mix.Tasks.Symphony.Task do
  @shortdoc "Create or update a local SQLite task"

  @moduledoc """
  Manages tasks for the `local` tracker (`tracker.kind: local` in WORKFLOW.md).

  Create (default status `queued` — does not auto-start Codex unless status is `running`):

      mix symphony.task "Fix login redirect"
      mix symphony.task "Summarize logs" --body "Check agent run output" --priority 2

  Update / cancel:

      mix symphony.task --id 1 --status cancelled
      mix symphony.task --id 1 --status running
  """

  use Mix.Task

  alias SymphonyElixir.Cursor.Dispatch
  alias SymphonyElixir.Tasks

  @switches [
    id: :integer,
    body: :string,
    status: :string,
    priority: :integer,
    project: :string,
    workspace_mode: :string,
    dispatch: :boolean,
    database: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, title_parts, _} = OptionParser.parse(argv, switches: @switches)

    if path = opts[:database] do
      Application.put_env(:symphony_elixir, :tasks_database_path, path)
    end

    Tasks.migrate()

    case opts[:id] do
      id when is_integer(id) -> update_task(id, opts)
      _ -> create_task(title_parts, opts)
    end
  end

  defp create_task(title_parts, opts) do
    title =
      title_parts
      |> Enum.join(" ")
      |> String.trim()

    if title == "" do
      Mix.raise(
        "usage: mix symphony.task \"Task title\" [--body ...] [--status queued] [--priority 1-4]\n" <>
          "       mix symphony.task --id 1 --status cancelled"
      )
    end

    attrs =
      %{
        title: title,
        body: opts[:body],
        status: opts[:status] || "queued",
        priority: opts[:priority],
        project_path: opts[:project],
        workspace_mode: opts[:workspace_mode] || "isolated"
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Tasks.create(attrs) do
      {:ok, task} ->
        issue = Tasks.to_issue(task)
        git = SymphonyElixir.Git.format_summary(task.git_metadata)
        Mix.shell().info("Created #{issue.identifier} (id=#{issue.id}, status=#{issue.state})")
        if task.project_path, do: Mix.shell().info("Project: #{task.project_path} · #{git}")

        if opts[:dispatch] do
          :ok = Dispatch.start_async(task.id, auto_plan: true, open_ide: false, run_agent: true)
          Mix.shell().info("Dispatched immediately. Default: add to queue and run `Go` on the dashboard.")
        end

      {:error, changeset} ->
        Mix.raise("failed to create task: #{inspect(changeset.errors)}")
    end
  end

  defp update_task(id, opts) do
    if is_binary(opts[:status]) do
      task = Tasks.update_status!(id, opts[:status])
      issue = Tasks.to_issue(task)
      Mix.shell().info("Updated #{issue.identifier} (id=#{issue.id}, status=#{issue.state})")
    else
      Mix.raise("usage: mix symphony.task --id #{id} --status <queued|running|done|cancelled|...>")
    end
  end
end
