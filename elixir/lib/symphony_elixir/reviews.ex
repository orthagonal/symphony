defmodule SymphonyElixir.Reviews do
  @moduledoc """
  Personal review tickets created when agent work completes.
  """

  import Ecto.Query

  require Logger

  alias SymphonyElixir.{Ollama, Tasks}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Reviews.ReviewTicket
  alias SymphonyElixir.Tasks.Task

  @pubsub SymphonyElixir.PubSub
  @topic "reviews"

  @spec list_all() :: [ReviewTicket.t()]
  def list_all do
    from(r in ReviewTicket, order_by: [desc: r.inserted_at], preload: [:task])
    |> Repo.all()
  end

  @spec list_open() :: [ReviewTicket.t()]
  def list_open do
    from(r in ReviewTicket,
      where: r.status == "open",
      order_by: [desc: r.inserted_at],
      preload: [:task]
    )
    |> Repo.all()
  end

  @spec get!(integer()) :: ReviewTicket.t()
  def get!(id), do: Repo.get!(ReviewTicket, id) |> Repo.preload(:task)

  @spec create_for_completed_task!(Task.t()) :: ReviewTicket.t()
  def create_for_completed_task!(%Task{} = task) do
    case Repo.get_by(ReviewTicket, task_id: task.id) do
      %ReviewTicket{} = existing ->
        existing

      nil ->
        ticket =
          %ReviewTicket{}
          |> ReviewTicket.changeset(%{
            task_id: task.id,
            title: "Review: #{task.title}",
            status: "open",
            summary: nil,
            checklist: default_checklist(task)
          })
          |> Repo.insert!()

        broadcast(:created, ticket)
        start_checklist_generation(ticket.id, task)
        ticket
    end
  end

  @spec toggle_checklist_item!(integer(), String.t()) :: ReviewTicket.t()
  def toggle_checklist_item!(ticket_id, item_id)
      when is_integer(ticket_id) and is_binary(item_id) do
    ticket = get!(ticket_id)

    checklist =
      Enum.map(ticket.checklist || [], fn item ->
        if item["id"] == item_id do
          Map.put(item, "done", !item["done"])
        else
          item
        end
      end)

    ticket
    |> ReviewTicket.changeset(%{checklist: checklist})
    |> Repo.update!()
    |> tap(&broadcast(:updated, &1))
  end

  @spec delete_tickets_for_task!(integer()) :: :ok
  def delete_tickets_for_task!(task_id) when is_integer(task_id) do
    from(r in ReviewTicket, where: r.task_id == ^task_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Marks any open review ticket for this task as done (checklist completed).
  """
  @spec complete_open_ticket_for_task!(integer()) :: :ok
  def complete_open_ticket_for_task!(task_id) when is_integer(task_id) do
    case Repo.get_by(ReviewTicket, task_id: task_id) do
      nil ->
        :ok

      %ReviewTicket{status: "done"} ->
        :ok

      %ReviewTicket{id: id} ->
        _ = complete!(id)
        :ok
    end
  end

  @spec complete!(integer()) :: ReviewTicket.t()
  def complete!(ticket_id) when is_integer(ticket_id) do
    ticket = get!(ticket_id)

    checklist =
      Enum.map(ticket.checklist || [], fn item -> Map.put(item, "done", true) end)

    ticket
    |> ReviewTicket.changeset(%{status: "done", checklist: checklist})
    |> Repo.update!()
    |> tap(&broadcast(:updated, &1))
  end

  @spec apply_generated_checklist!(integer(), String.t(), String.t()) :: :ok
  def apply_generated_checklist!(ticket_id, summary, raw_items)
      when is_integer(ticket_id) and is_binary(raw_items) do
    items = parse_checklist_items(raw_items)

    case get!(ticket_id) do
      %ReviewTicket{status: "done"} ->
        :ok

      ticket ->
        ticket
        |> ReviewTicket.changeset(%{
          summary: String.trim(summary || ""),
          checklist: items
        })
        |> Repo.update!()

        broadcast(:updated, ticket)
        :ok
    end
  rescue
    error ->
      Logger.warning("apply_generated_checklist failed ticket_id=#{ticket_id} error=#{inspect(error)}")
      :ok
  end

  defp start_checklist_generation(ticket_id, %Task{} = task) do
    Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      task = Tasks.get_with_events!(task.id)
      payload = review_payload(task)

      case Ollama.review_checklist(payload) do
        {:ok, %{summary: summary, items: items}} ->
          apply_generated_checklist!(ticket_id, summary, items)

        {:error, reason} ->
          Logger.warning("review checklist generation failed: #{inspect(reason)}")
      end
    end)
  end

  defp review_payload(%Task{} = task) do
    events = Tasks.list_events(task.id)

    log_excerpt =
      events
      |> Enum.take(40)
      |> Enum.map(fn e -> "[#{e.kind}] #{String.slice(e.message || "", 0, 500)}" end)
      |> Enum.join("\n")

    %{
      title: task.title,
      body: task.body,
      project_path: task.project_path,
      workspace_path: task.workspace_path,
      git_metadata: task.git_metadata,
      log: log_excerpt
    }
  end

  defp default_checklist(%Task{} = task) do
    [
      %{
        "id" => "diff",
        "label" => "Review code changes for: #{task.title}",
        "done" => false
      },
      %{
        "id" => "workspace",
        "label" => "Confirm workspace is clean and on the expected branch",
        "done" => false
      }
    ]
  end

  defp parse_checklist_items(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      label = line |> String.replace(~r/^[-*]\s*/, "") |> String.trim()

      %{
        "id" => "item-#{idx}",
        "label" => label,
        "done" => false
      }
    end)
    |> case do
      [] -> default_checklist(%Task{title: "task"})
      items -> items
    end
  end

  defp broadcast(event, %ReviewTicket{} = ticket) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {event, ticket.id})
  end
end
