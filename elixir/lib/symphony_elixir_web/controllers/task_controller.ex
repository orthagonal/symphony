defmodule SymphonyElixirWeb.TaskController do
  @moduledoc """
  Plain HTTP create for tasks (works when LiveView socket is slow or disconnected).
  """

  use Phoenix.Controller, formats: [:html]

  require Logger

  alias SymphonyElixir.Cursor.Dispatch
  alias SymphonyElixir.LocalDispatch
  alias SymphonyElixir.Tasks

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"task" => task_params} = params) do
    manual? = manual_dispatch?(params)

    case Tasks.create(normalize_params(task_params)) do
      {:ok, task} ->
        log_created(task.id)
        maybe_start_dispatch(task.id, manual?)

        conn
        |> put_flash(:info, create_flash(task, manual?))
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
      task = Tasks.get!(task_id)

      :ok =
        if task.local_only do
          LocalDispatch.start_async(task_id, [])
        else
          Dispatch.start_async(task_id, dispatch_opts(conn.params))
        end

      conn
      |> put_flash(:info, dispatch_flash(task))
      |> redirect(to: "/tasks/#{task_id}")
    else
      :error ->
        conn
        |> put_flash(:error, "Invalid task id")
        |> redirect(to: "/")
    end
  end

  defp maybe_start_dispatch(task_id, false) do
    task = Tasks.get!(task_id)

    :ok =
      if task.local_only do
        LocalDispatch.start_async(task_id, [])
      else
        Dispatch.start_async(task_id, default_dispatch_opts())
      end
  end

  defp maybe_start_dispatch(_task_id, true), do: :ok

  defp create_flash(%{local_only: true}, true),
    do: "Local-only task added to the queue. Click Go on the dashboard when ready."

  defp create_flash(%{local_only: true}, false),
    do: "Local-only task created — Ollama will implement in the workspace. Watch the task log."

  defp create_flash(_task, true),
    do: "Task added to the queue. Click Go on the dashboard when ready."

  defp create_flash(_task, false),
    do:
      "Task created — Ollama is planning and headless cursor-agent will start immediately. Watch the task log."

  defp dispatch_flash(%{local_only: true}),
    do: "Local dispatch started: Ollama will implement in the workspace. Watch the task log."

  defp dispatch_flash(_task),
    do:
      "Dispatch started: plan → workspace → headless cursor-agent. Watch the task log (may take several minutes)."

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
    |> Map.update("local_only", false, fn
      "true" -> true
      true -> true
      _ -> false
    end)
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
