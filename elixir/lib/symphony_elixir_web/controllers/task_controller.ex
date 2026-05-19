defmodule SymphonyElixirWeb.TaskController do
  @moduledoc """
  Plain HTTP create for tasks (works when LiveView socket is slow or disconnected).
  """

  use Phoenix.Controller, formats: [:html]

  require Logger

  alias SymphonyElixir.Cursor.Dispatch
  alias SymphonyElixir.Tasks

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"task" => task_params} = params) do
    manual? = manual_dispatch?(params)

    case Tasks.create(normalize_params(task_params)) do
      {:ok, task} ->
        log_created(task.id)
        maybe_start_dispatch(task.id, manual?)

        conn
        |> put_flash(:info, create_flash(manual?))
        |> redirect(to: "/tasks/#{task.id}")

      {:error, changeset} ->
        Logger.warning("task create validation failed errors=#{inspect(changeset.errors)}")

        conn
        |> put_flash(:error, format_errors(changeset))
        |> redirect(to: "/tasks/new")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Missing task fields")
    |> redirect(to: "/tasks/new")
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {task_id, ""} ->
        _ = Tasks.delete!(task_id)

        conn
        |> put_flash(:info, "Task deleted.")
        |> redirect(to: "/")

      _ ->
        conn
        |> put_flash(:error, "Invalid task id")
        |> redirect(to: "/")
    end
  end

  @spec dispatch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dispatch(conn, %{"id" => id}) do
    with {task_id, ""} <- Integer.parse(id) do
      :ok = Dispatch.start_async(task_id, dispatch_opts(conn.params))

      conn
      |> put_flash(
        :info,
        "Dispatch started: plan → workspace → headless cursor-agent. Watch the task log (may take several minutes)."
      )
      |> redirect(to: "/tasks/#{task_id}")
    else
      :error ->
        conn
        |> put_flash(:error, "Invalid task id")
        |> redirect(to: "/")
    end
  end

  defp maybe_start_dispatch(task_id, false) do
    :ok = Dispatch.start_async(task_id, default_dispatch_opts())
  end

  defp maybe_start_dispatch(_task_id, true), do: :ok

  defp create_flash(true),
    do: "Task added to the queue. Click Go on the dashboard when ready."

  defp create_flash(false),
    do:
      "Task created — Ollama is planning and headless cursor-agent will start immediately. Watch the task log."

  defp manual_dispatch?(params) when is_map(params) do
    not param_flag(params, "dispatch_immediately", false)
  end

  defp default_dispatch_opts do
    [auto_plan: true, open_ide: false, run_agent: true]
  end

  defp dispatch_opts(params) when is_map(params) do
    Keyword.merge(default_dispatch_opts(),
      auto_plan: param_flag(params, "auto_plan", true),
      open_ide: param_flag(params, "open_ide", false),
      run_agent: param_flag(params, "run_agent", true)
    )
  end

  defp param_flag(params, key, default) do
    case Map.get(params, key) do
      "false" -> false
      "0" -> false
      false -> false
      nil -> default
      _ -> true
    end
  end

  defp normalize_params(params) when is_map(params) do
    params
    |> Map.update("priority", nil, &normalize_priority/1)
    |> Map.update("assigned_agent", nil, &blank_to_nil/1)
    |> Map.update("body", nil, &blank_to_nil/1)
    |> Map.update("project_path", nil, &blank_to_nil/1)
  end

  defp normalize_priority(""), do: nil
  defp normalize_priority(nil), do: nil

  defp normalize_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp normalize_priority(value), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp log_created(task_id) do
    Tasks.log_event!(task_id, "created", "Task created from dashboard")
  rescue
    error ->
      Logger.warning("task create log_event failed task_id=#{task_id} error=#{inspect(error)}")
  end

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end
end
