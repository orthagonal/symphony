defmodule SymphonyElixirWeb.QueueController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias SymphonyElixir.TaskQueue

  def go(conn, _params) do
    case TaskQueue.status() do
      %{status: :running} ->
        conn
        |> put_flash(:info, "Queue is already running.")
        |> redirect(to: "/")

      _ ->
        TaskQueue.go()

        conn
        |> put_flash(:info, "Go — processing queued tasks one at a time.")
        |> redirect(to: "/")
    end
  end

  def stop(conn, _params) do
    TaskQueue.stop_processing()

    conn
    |> put_flash(:info, "Queue stopped (current task may still finish).")
    |> redirect(to: "/")
  end
end
