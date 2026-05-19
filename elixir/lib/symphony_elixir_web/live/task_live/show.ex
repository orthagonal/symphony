defmodule SymphonyElixirWeb.TaskLive.Show do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Cursor, Cursor.WorkspaceBootstrap, Ollama, Tasks, Workspace}
  alias SymphonyElixir.Tasks.Task
  import SymphonyElixirWeb.Components.Nav

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {task_id, ""} ->
        if connected?(socket), do: schedule_refresh()

        {:ok,
         socket
         |> assign(:page, :task)
         |> assign(:task_id, task_id)
         |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
         |> assign(:llm_busy, false)
         |> assign(:llm_output, nil)
         |> assign(:note, "")
         |> load_task()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid task id")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("set_status", %{"status" => status}, socket) do
    task = Tasks.update_status!(socket.assigns.task_id, status)
    _ = Tasks.log_event!(task.id, "status", "Status → #{status}")

    {:noreply,
     socket
     |> put_flash(:info, "Status updated")
     |> assign(:task, Tasks.get_with_events!(task.id))}
  end

  @impl true
  def handle_event("add_note", %{"note" => note}, socket) do
    note = String.trim(note)

    if note != "" do
      _ = Tasks.log_event!(socket.assigns.task_id, "comment", note)
    end

    {:noreply,
     socket
     |> assign(:note, "")
     |> load_task()}
  end

  @impl true
  def handle_event("summarize", _params, socket) do
    run_llm(socket, :summarize)
  end

  @impl true
  def handle_event("plan", _params, socket) do
    run_llm(socket, :plan)
  end

  @impl true
  def handle_event("prepare_workspace", _params, socket) do
    identifier = "TASK-#{socket.assigns.task_id}"
    task = Tasks.get_with_events!(socket.assigns.task_id)

    with {:ok, path} <- Workspace.create_for_issue(identifier),
         {:ok, path} <- WorkspaceBootstrap.bootstrap(path, task),
         task <- Tasks.update!(task.id, %{workspace_path: path}) do
      _ = Tasks.log_event!(task.id, "workspace", "Workspace seeded at #{path}")

      {:noreply,
       socket
       |> put_flash(:info, "Workspace prepared (repo copy + SYMPHONY_TASK.md)")
       |> load_task()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Workspace failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("open_in_cursor", _params, socket) do
    task = socket.assigns.task

    case task.workspace_path do
      path when is_binary(path) and path != "" ->
        identifier = "TASK-#{task.id}"

        case Cursor.open_workspace_file(path, identifier) do
          {:ok, _} ->
            _ = Tasks.log_event!(task.id, "cursor", "Opened in Cursor")

            {:noreply,
             socket
             |> put_flash(:info, "Launched Cursor")
             |> load_task()}

          {:error, :cursor_cli_not_found} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "cursor CLI not on PATH. Use: cursor #{path} or install from Cursor → Command Palette → Shell Command."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not open Cursor: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Prepare workspace first")}
    end
  end

  @impl true
  def handle_info(:refresh_task, socket) do
    schedule_refresh()
    {:noreply, load_task(socket)}
  end

  @impl true
  def handle_info({:llm_done, kind, result}, socket) do
    case result do
      {:ok, text} ->
        kind_label = if kind == :plan, do: "plan", else: "summary"
        _ = Tasks.log_event!(socket.assigns.task_id, "llm_#{kind_label}", text)

        {:noreply,
         socket
         |> assign(:llm_busy, false)
         |> assign(:llm_output, text)
         |> load_task()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:llm_busy, false)
         |> assign(:llm_output, "Ollama error: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">TASK-<%= @task.id %></p>
            <h1 class="hero-title"><%= @task.title %></h1>
            <p class="hero-copy">
              <span class={state_badge_class(@task.status)}><%= @task.status %></span>
              <%= if @task.assigned_agent, do: " · #{@task.assigned_agent}" %>
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <div class="detail-grid">
        <section class="section-card">
          <h2 class="section-title">Project</h2>
          <p class="mono workspace-path">
            <%= @task.project_path || "Default (WORKFLOW seed_path)" %>
          </p>
          <p class="section-copy">
            Mode: <strong><%= @task.workspace_mode %></strong>
            <%= if @task.workspace_path do %>
              · Workspace: <%= @task.workspace_path %>
            <% end %>
          </p>
          <p class="section-copy">
            <strong>Git:</strong> <%= SymphonyElixir.Git.format_summary(@task.git_metadata) %>
          </p>
          <pre :if={@task.git_metadata} class="llm-box"><%= format_git_metadata(@task.git_metadata) %></pre>
        </section>

        <section class="section-card">
          <h2 class="section-title">Description</h2>
          <pre class="task-body"><%= @task.body || "No description." %></pre>
          <p :if={@task.result} class="task-result">
            <strong>Result:</strong> <%= @task.result %>
          </p>

          <div class="status-actions">
            <button
              :for={status <- Task.statuses()}
              type="button"
              class="secondary"
              phx-click="set_status"
              phx-value-status={status}
            >
              <%= status %>
            </button>
          </div>
          <div class="delete-task-wrap">
            <form
              action={"/tasks/#{@task.id}/delete"}
              method="post"
              class="delete-task-form"
              onsubmit={"return confirm('Delete TASK-#{@task.id} permanently? This cannot be undone.');"}
            >
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <button type="submit" class="danger">Delete task</button>
            </form>
          </div>
        </section>

        <section class="section-card">
          <h2 class="section-title">Ollama</h2>
          <p class="section-copy">Model: <%= Ollama.model() %> @ <%= Ollama.base_url() %></p>
          <div class="form-actions">
            <button type="button" phx-click="summarize" disabled={@llm_busy}>Summarize</button>
            <button type="button" class="secondary" phx-click="plan" disabled={@llm_busy}>Plan for Cursor</button>
          </div>
          <pre :if={@llm_output} class="llm-box"><%= @llm_output %></pre>
        </section>

        <section class="section-card dispatch-card">
          <h2 class="section-title">Dispatch</h2>
          <p class="section-copy">
            Runs <code>cursor-agent --print --yolo</code> in the task workspace (headless). Optional: open Cursor IDE.
          </p>
          <form action={"/tasks/#{@task.id}/dispatch"} method="post" class="dispatch-form">
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label class="dispatch-option">
              <input type="checkbox" name="open_ide" value="true" />
              Also open Cursor IDE
            </label>
            <button type="submit" class="dispatch-button">Dispatch (headless agent)</button>
          </form>
          <p class="section-copy">
            Agent: <%= if @handoff.agent_path, do: @handoff.agent_path, else: "not found" %>
            · Auth: <%= if @handoff.agent_authenticated, do: "logged in", else: "not logged in" %>
          </p>
          <p :if={!@handoff.agent_installed} class="section-copy">
            Install Cursor Agent:
            <code>irm https://cursor.com/install?win32=true | iex</code>
          </p>
          <p :if={@handoff.agent_installed and !@handoff.agent_authenticated} class="section-copy dispatch-warning">
            <strong>cursor-agent auth check failed.</strong>
            Run <code>cursor-agent.cmd login</code> in PowerShell, restart Symphony, refresh this page.
          </p>
        </section>

        <section class="section-card">
          <h2 class="section-title">Cursor (manual)</h2>
          <p class="section-copy">Or run each step yourself.</p>
          <div class="form-actions">
            <button type="button" phx-click="prepare_workspace">Prepare workspace</button>
            <button
              :if={@task.workspace_path}
              type="button"
              class="secondary"
              phx-click="open_in_cursor"
            >
              Open in Cursor
            </button>
          </div>
          <p :if={@handoff.workspace_path} class="mono workspace-path"><%= @handoff.workspace_path %></p>
          <p :if={@handoff.workspace_file} class="mono"><%= @handoff.workspace_file %></p>
          <pre class="llm-box"><%= @handoff.instructions %></pre>
          <p :if={@handoff.open_command} class="mono"><%= @handoff.open_command %></p>
          <p :if={@handoff.agent_command} class="mono"><%= @handoff.agent_command %></p>
          <p :if={!@handoff.agent_installed} class="section-copy">
            Cursor CLI (`agent`) not on PATH —
            <code>irm https://cursor.com/install?win32=true | iex</code>
            then restart the terminal.
          </p>
        </section>

        <section class="section-card form-span-all">
          <h2 class="section-title">Log</h2>
          <.form for={%{}} phx-submit="add_note" class="note-form">
            <input type="text" name="note" value={@note} placeholder="Add note…" />
            <button type="submit" class="secondary">Add</button>
          </.form>
          <ul class="event-log">
            <li :for={event <- @task.events}>
              <span class="event-time"><%= format_ts(event.inserted_at) %></span>
              <span class="event-kind"><%= event.kind %></span>
              <span class="event-msg"><%= event.message %></span>
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  defp load_task(socket) do
    task = Tasks.get_with_events!(socket.assigns.task_id)

    socket
    |> assign(:task, task)
    |> assign(:handoff, handoff_for(task))
  end

  defp handoff_for(task) do
    Cursor.handoff(%{
      workspace_path: task.workspace_path,
      identifier: "TASK-#{task.id}"
    })
  end

  defp run_llm(socket, kind) do
    task = socket.assigns.task
    parent = self()

    payload = task_payload(task)

    Elixir.Task.start(fn ->
      result =
        case kind do
          :plan -> Ollama.plan_task(payload)
          _ -> Ollama.summarize_task(payload)
        end

      send(parent, {:llm_done, kind, result})
    end)

    {:noreply,
     socket
     |> assign(:llm_busy, true)
     |> assign(:llm_output, "Waiting for Ollama…")}
  end

  defp state_badge_class(status) do
    "state-badge state-badge-" <> String.replace(status, " ", "-")
  end

  defp task_payload(task) do
    %{
      title: task.title,
      body: task.body,
      status: task.status,
      events: task.events || []
    }
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_task, 4_000)
  end

  defp format_git_metadata(nil), do: ""

  defp format_git_metadata(meta) when is_map(meta) do
    meta
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(_), do: "?"
end
