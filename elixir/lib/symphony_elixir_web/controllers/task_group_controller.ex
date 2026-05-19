defmodule SymphonyElixirWeb.TaskGroupController do
  @moduledoc """
  Plain HTTP actions for task groups (delete uses a form POST like single tasks).
  """

  use Phoenix.Controller, formats: [:html]

  alias SymphonyElixir.TaskGroups

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {group_id, ""} ->
        :ok = TaskGroups.delete_group!(group_id)

        conn
        |> put_flash(:info, "Task group and all tasks deleted.")
        |> redirect(to: "/task-groups")

      _ ->
        conn
        |> put_flash(:error, "Invalid group id")
        |> redirect(to: "/task-groups")
    end
  end
end
