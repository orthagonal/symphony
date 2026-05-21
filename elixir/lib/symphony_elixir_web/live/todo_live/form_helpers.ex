defmodule SymphonyElixirWeb.TodoLive.FormHelpers do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixir.Todos.TodoItem

  attr(:form, :any, required: true)
  attr(:submit_label, :string, default: "Save")

  def todo_form(assigns) do
    ~H"""
    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save" class="todo-form">
      <label>
        Title
        <input type="text" name={@form[:title].name} value={@form[:title].value} required />
      </label>

      <label>
        Notes
        <textarea name={@form[:notes].name} rows="4"><%= @form[:notes].value %></textarea>
      </label>

      <label>
        Status
        <select name={@form[:status].name}>
          <option
            :for={status <- TodoItem.statuses()}
            value={status}
            selected={@form[:status].value == status}
          >
            <%= status_label(status) %>
          </option>
        </select>
      </label>

      <label>
        Due date (optional)
        <input type="datetime-local" name={@form[:due_at].name} value={@form[:due_at].value} />
      </label>

      <label>
        Task group id (optional)
        <input type="number" name={@form[:task_group_id].name} value={@form[:task_group_id].value} min="1" />
      </label>

      <label>
        Task id (optional)
        <input type="number" name={@form[:task_id].name} value={@form[:task_id].value} min="1" />
      </label>

      <button type="submit"><%= @submit_label %></button>
    </.form>
    """
  end

  @spec normalize_params(map()) :: map()
  def normalize_params(params) when is_map(params) do
    params
    |> Map.update("due_at", nil, &parse_due_at/1)
    |> Map.update("task_group_id", nil, &blank_to_nil/1)
    |> Map.update("task_id", nil, &blank_to_nil/1)
  end

  defp parse_due_at(nil), do: nil
  defp parse_due_at(""), do: nil

  defp parse_due_at(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value <> ":00") do
      {:ok, naive} ->
        naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:microsecond)

      {:error, _} ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            date
            |> DateTime.new!(~T[00:00:00], "Etc/UTC")
            |> DateTime.truncate(:microsecond)

          _ ->
            nil
        end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp status_label("needFinishing"), do: "Need finishing"
  defp status_label(status), do: status

  @spec format_due_for_input(DateTime.t() | nil) :: String.t() | nil
  def format_due_for_input(nil), do: nil

  def format_due_for_input(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end
end
