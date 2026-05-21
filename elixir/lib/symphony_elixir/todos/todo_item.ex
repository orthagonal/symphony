defmodule SymphonyElixir.Todos.TodoItem do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.TaskGroups.TaskGroup
  alias SymphonyElixir.Tasks.Task

  @statuses ~w(queued blocked needFinishing finished)

  schema "todos" do
    field :title, :string
    field :notes, :string
    field :status, :string, default: "queued"
    field :due_at, :utc_datetime_usec
    field :links, {:array, :string}, default: []
    field :checklist, {:array, :map}, default: []

    belongs_to :task_group, TaskGroup
    belongs_to :task, Task

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(todo, attrs) do
    todo
    |> cast(attrs, [:title, :notes, :status, :due_at, :links, :checklist, :task_group_id, :task_id])
    |> validate_required([:title, :status])
    |> validate_inclusion(:status, @statuses)
    |> normalize_links()
    |> normalize_checklist()
    |> normalize_optional_ids()
    |> validate_due_at()
  end

  defp normalize_links(changeset) do
    case get_change(changeset, :links) || get_field(changeset, :links) do
      nil ->
        changeset

      links when is_list(links) ->
        cleaned =
          links
          |> Enum.map(&normalize_link/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :links, cleaned)

      _ ->
        changeset
    end
  end

  defp normalize_link(link) when is_binary(link), do: String.trim(link)
  defp normalize_link(link), do: link |> to_string() |> String.trim()

  defp normalize_checklist(changeset) do
    case get_change(changeset, :checklist) || get_field(changeset, :checklist) do
      nil ->
        changeset

      checklist when is_list(checklist) ->
        cleaned =
          checklist
          |> Enum.map(&normalize_checklist_item/1)
          |> Enum.reject(&(&1["text"] == ""))

        put_change(changeset, :checklist, cleaned)

      _ ->
        changeset
    end
  end

  defp normalize_checklist_item(%{"text" => text} = item) do
    %{
      "text" => text |> to_string() |> String.trim(),
      "done" => checklist_done?(item)
    }
  end

  defp normalize_checklist_item(%{text: text} = item) do
    %{
      "text" => text |> to_string() |> String.trim(),
      "done" => checklist_done?(item)
    }
  end

  defp normalize_checklist_item(text) when is_binary(text) do
    %{"text" => String.trim(text), "done" => false}
  end

  defp normalize_checklist_item(_), do: %{"text" => "", "done" => false}

  defp checklist_done?(%{"done" => done}), do: done in [true, "true", 1, "1"]
  defp checklist_done?(%{done: done}), do: done in [true, "true", 1, "1"]
  defp checklist_done?(_), do: false

  defp normalize_optional_ids(changeset) do
    changeset
    |> blank_id_to_nil(:task_group_id)
    |> blank_id_to_nil(:task_id)
  end

  defp blank_id_to_nil(changeset, field) do
    case get_change(changeset, field) || get_field(changeset, field) do
      "" -> put_change(changeset, field, nil)
      nil -> changeset
      id when is_integer(id) -> changeset
      id when is_binary(id) ->
        case Integer.parse(String.trim(id)) do
          {n, ""} -> put_change(changeset, field, n)
          _ -> add_error(changeset, field, "must be a number")
        end

      _ ->
        changeset
    end
  end

  defp validate_due_at(changeset) do
    validate_change(changeset, :due_at, fn :due_at, due_at ->
      cond do
        is_nil(due_at) -> []
        match?(%DateTime{}, due_at) -> []
        true -> [due_at: "must be a valid datetime"]
      end
    end)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
