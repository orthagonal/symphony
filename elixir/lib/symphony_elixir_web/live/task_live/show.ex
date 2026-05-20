defmodule SymphonyElixirWeb.TaskLive.Show do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Repo
  alias SymphonyElixir.{AgentBackend, AgentDispatch, Cursor, Cursor.WorkspaceBootstrap, OS, Ollama, Tasks, Workspace}
  alias SymphonyElixir.Tasks.Task
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.Components.TaskBadges

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
         |> assign(:editing, false)
         |> load_task()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid task id")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign_edit_form()}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, false)}
  end

  @impl true
  def handle_event("validate", %{"task" => params}, socket) do
    changeset =
      socket.assigns.task
      |> Task.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :task))}
  end

  @impl true
  def handle_event("save", %{"task" => params}, socket) do
    params = normalize_params(params)

    case socket.assigns.task |> Task.changeset(params) |> Repo.update() do
      {:ok, task} ->
        _ = Tasks.log_event!(task.id, "updated", "Task fields updated")

        {:noreply,
         socket
         |> assign(:editing, false)
         |> put_flash(:info, "Task saved")
         |> load_task()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Fix the errors below")
         |> assign(:form, to_form(changeset, as: :task, action: :update))}
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
  def handle_event("open_in_explorer", _params, socket) do
    task = socket.assigns.task

    case task.workspace_path do
      path when is_binary(path) and path != "" ->
        case OS.open_in_file_explorer(path) do
          :ok ->
            _ = Tasks.log_event!(task.id, "explorer", "Opened workspace in File Explorer")

            {:noreply, put_flash(socket, :info, "Opened in File Explorer")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not open File Explorer: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Prepare workspace first")}
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
    if socket.assigns.editing do
      schedule_refresh()
      {:noreply, socket}
    else
      schedule_refresh()
      {:noreply, load_task(socket)}
    end
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
              <.task_badges :if={@task.local_only or @task.task_group_id} task={@task} />
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <div class="detail-grid">
        <section class="section-card form-span-all">
          <div class="form-actions" style="margin-bottom: 1rem;">
            <h2 class="section-title" style="margin: 0; flex: 1;">Task details</h2>
            <button :if={!@editing} type="button" class="secondary" phx-click="edit">
              Edit task
            </button>
          </div>

          <div :if={!@editing}>
            <p class="section-copy">
              <strong>Priority:</strong> <%= @task.priority || "—" %>
              · <strong>Status:</strong> <%= @task.status %>
            </p>
            <p class="mono workspace-path">
              <%= @task.project_path || "Default (WORKFLOW seed_path)" %>
            </p>
            <p class="section-copy">
              Mode: <strong><%= @task.workspace_mode %></strong>
              <%= if @task.workspace_path do %>
                · Workspace:
                <button
                  type="button"
                  class="path-link"
                  phx-click="open_in_explorer"
                  title="Open in File Explorer"
                >
                  <%= @task.workspace_path %>
                </button>
              <% end %>
            </p>
            <p class="section-copy">
              <strong>Git:</strong> <%= SymphonyElixir.Git.format_summary(@task.git_metadata) %>
            </p>
            <pre :if={@task.git_metadata} class="llm-box"><%= format_git_metadata(@task.git_metadata) %></pre>
            <pre class="task-body"><%= @task.body || "No description." %></pre>
            <p :if={@task.result} class="task-result">
              <strong>Result:</strong> <%= @task.result %>
            </p>
            <p :if={@task.local_only} class="section-copy">Local only (Ollama)</p>
          </div>

          <.form
            :if={@editing}
            for={@form}
            id="task-edit-form"
            phx-change="validate"
            phx-submit="save"
          >
            <div class="form-grid">
              <label>
                <span>Title</span>
                <input type="text" name={@form[:title].name} value={@form[:title].value} required />
                <span :for={msg <- @form[:title].errors} class="field-error"><%= msg %></span>
              </label>
              <label>
                <span>Priority (1–4)</span>
                <input
                  type="number"
                  name={@form[:priority].name}
                  value={@form[:priority].value}
                  min="1"
                  max="4"
                />
              </label>
              <label class="form-span-all">
                <span>Project folder</span>
                <input
                  type="text"
                  name={@form[:project_path].name}
                  value={@form[:project_path].value}
                  placeholder="C:/GitHub/my-app (leave empty for Symphony default)"
                />
                <span :for={msg <- @form[:project_path].errors} class="field-error"><%= msg %></span>
                <span class="section-copy">Git metadata refreshes when you save.</span>
              </label>
              <label>
                <span>Workspace mode</span>
                <select name={@form[:workspace_mode].name}>
                  <option
                    :for={mode <- Task.workspace_modes()}
                    value={mode}
                    selected={@form[:workspace_mode].value == mode}
                  >
                    <%= workspace_mode_label(mode) %>
                  </option>
                </select>
              </label>
              <label>
                <span>Status</span>
                <select name={@form[:status].name}>
                  <option :for={s <- Task.statuses()} value={s} selected={@form[:status].value == s}>
                    <%= s %>
                  </option>
                </select>
              </label>
              <label class="form-span-all">
                <span>Description</span>
                <textarea name={@form[:body].name} rows="8">{@form[:body].value}</textarea>
              </label>
              <label>
                <span>Assigned agent</span>
                <select name={@form[:assigned_agent].name}>
                  <option value="">cursor (default)</option>
                  <option
                    :for={backend <- Task.agent_backends()}
                    value={backend}
                    selected={@form[:assigned_agent].value == backend}
                  >
                    <%= AgentBackend.label(backend) %>
                  </option>
                </select>
              </label>
              <label class="form-span-all dispatch-option">
                <input
                  type="checkbox"
                  name={@form[:local_only].name}
                  value="true"
                  checked={@form[:local_only].value in [true, "true"]}
                />
                <span>Local only (Ollama — ignores agent selection)</span>
              </label>
            </div>
            <div class="form-actions">
              <button type="submit">Save changes</button>
              <button type="button" class="secondary" phx-click="cancel_edit">Cancel</button>
            </div>
          </.form>

          <div :if={!@editing} class="status-actions">
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
            Backend: <strong><%= AgentBackend.label(@resolved_agent) %></strong>
            <%= if @task.local_only, do: " (local only overrides selection)" %>
          </p>
          <p class="section-copy"><%= @dispatch_hint %></p>
          <form action={"/tasks/#{@task.id}/dispatch"} method="post" class="dispatch-form">
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label :if={@resolved_agent == "cursor" and !@task.local_only} class="dispatch-option">
              <input type="checkbox" name="open_ide" value="true" />
              Also open Cursor IDE
            </label>
            <button type="submit" class="dispatch-button">
              Dispatch (<%= @resolved_agent %>)
            </button>
          </form>
          <p :if={@handoff.agent_path} class="section-copy">
            CLI: <span class="mono"><%= @handoff.agent_path %></span>
            · Auth: <%= if @handoff.agent_authenticated == :ok, do: "ready", else: "check setup" %>
          </p>
          <p :if={!@handoff.agent_installed} class="section-copy dispatch-warning">
            <%= @handoff.instructions %>
          </p>
          <p
            :if={@handoff.agent_installed and @handoff.agent_authenticated != :ok and @resolved_agent == "cursor"}
            class="section-copy dispatch-warning"
          >
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
            <button
              :if={@task.workspace_path}
              type="button"
              class="secondary"
              phx-click="open_in_explorer"
            >
              Open in Explorer
            </button>
          </div>
          <p :if={@handoff.workspace_path} class="mono workspace-path">
            <button
              type="button"
              class="path-link"
              phx-click="open_in_explorer"
              title="Open in File Explorer"
            >
              <%= @handoff.workspace_path %>
            </button>
          </p>
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

    resolved = AgentBackend.resolve(task)

    socket =
      socket
      |> assign(:task, task)
      |> assign(:resolved_agent, resolved)
      |> assign(:dispatch_hint, dispatch_hint(resolved, task))
      |> assign(:handoff, handoff_for(task, resolved))

    if socket.assigns.editing do
      assign_edit_form(socket, task)
    else
      socket
    end
  end

  defp assign_edit_form(socket, task \\ nil) do
    task = task || socket.assigns.task
    changeset = Task.changeset(task, %{})
    assign(socket, :form, to_form(changeset, as: :task))
  end

  defp handoff_for(task, resolved_agent) do
    AgentDispatch.handoff(%{
      workspace_path: task.workspace_path,
      identifier: "TASK-#{task.id}",
      backend: resolved_agent
    })
  end

  defp dispatch_hint("ollama", %{local_only: true}),
    do: "Runs Ollama in the workspace. Use queue Go or dispatch below."

  defp dispatch_hint("ollama", _),
    do: "Runs Ollama chat completion in the workspace (no external agent CLI)."

  defp dispatch_hint("codex", _),
    do: "Runs `codex app-server` in the workspace (same stack as the Codex orchestrator)."

  defp dispatch_hint("zed", _),
    do: "Runs Zed `eval-cli` headless agent. Requires eval-cli on PATH or ZED_COMMAND."

  defp dispatch_hint("cursor", _),
    do: "Runs `cursor-agent --print --yolo` in the task workspace. Optional: open Cursor IDE."

  defp dispatch_hint(_, _), do: "Dispatch runs the selected agent in the workspace."

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

  defp workspace_mode_label("isolated"), do: "Isolated copy (TASK-N folder, no .git)"
  defp workspace_mode_label("linked"), do: "Linked (work directly in project folder)"
  defp workspace_mode_label(other), do: other

  defp normalize_params(params) when is_map(params) do
    params
    |> Map.update("local_only", false, fn
      "true" -> true
      true -> true
      _ -> false
    end)
    |> Map.update("priority", nil, fn
      "" -> nil
      nil -> nil
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value
        end

      value ->
        value
    end)
    |> Map.update("project_path", nil, &blank_to_nil/1)
    |> Map.update("assigned_agent", nil, &blank_to_nil/1)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
