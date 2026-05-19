defmodule SymphonyElixirWeb.TasksApiController do
  @moduledoc """
  JSON API for local tasks and Ollama helpers (no auth for now).
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.{Ollama, Tasks}

  @spec summarize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summarize(conn, %{"id" => id}) do
    with {task_id, ""} <- Integer.parse(id),
         task <- Tasks.get_with_events!(task_id),
         {:ok, text} <-
           Ollama.summarize_task(%{
             title: task.title,
             body: task.body,
             status: task.status,
             events: task.events
           }) do
      _ = Tasks.log_event!(task_id, "summary", text)

      json(conn, %{ok: true, summary: text, model: Ollama.model()})
    else
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_task_id"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: "ollama_failed", detail: inspect(reason)})
    end
  end

  @spec plan(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def plan(conn, %{"id" => id}) do
    with {task_id, ""} <- Integer.parse(id),
         task <- Tasks.get_with_events!(task_id),
         {:ok, text} <-
           Ollama.plan_task(%{title: task.title, body: task.body, status: task.status}) do
      _ = Tasks.log_event!(task_id, "plan", text)

      json(conn, %{ok: true, plan: text, model: Ollama.model()})
    else
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_task_id"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: "ollama_failed", detail: inspect(reason)})
    end
  end

  @spec update_status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_status(conn, %{"id" => id} = params) do
    status = Map.get(params, "status") || get_json_status(conn)

    with {task_id, ""} <- Integer.parse(id),
         status when is_binary(status) and status != "" <- status,
         task <- Tasks.update_status!(task_id, status) do
      _ = Tasks.log_event!(task_id, "status", "API → #{status}")

      json(conn, %{ok: true, id: task.id, status: task.status})
    else
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_task_id"})

      _ ->
        conn |> put_status(400) |> json(%{error: "missing_status", example: %{status: "review"}})
    end
  end

  defp get_json_status(conn) do
    case conn.body_params do
      %{"status" => status} when is_binary(status) -> status
      _ -> nil
    end
  end

  @spec list(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list(conn, _params) do
    tasks =
      Tasks.list_all()
      |> Enum.map(fn t ->
        %{id: t.id, title: t.title, status: t.status, priority: t.priority, inserted_at: t.inserted_at}
      end)

    json(conn, %{tasks: tasks})
  end
end
