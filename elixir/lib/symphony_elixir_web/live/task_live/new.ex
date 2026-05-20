defmodule SymphonyElixirWeb.TaskLive.New do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  require Logger

  alias SymphonyElixir.{Ollama, TaskGroups, Tasks}
  alias SymphonyElixir.Tasks.Task
  import SymphonyElixirWeb.Components.Nav

  @impl true
  def mount(_params, _session, socket) do
    changeset =
      Task.changeset(%Task{}, %{
        status: "queued",
        priority: 3,
        workspace_mode: "isolated"
      })

    {:ok,
     socket
     |> assign(:page, :new_task)
     |> assign(:form, to_form(changeset, as: :task))
     |> assign(:llm_busy, false)
     |> assign(:llm_hint, nil)
     |> assign(:group_description, "")
     |> assign(:group_busy, false)}
  end

  @impl true
  def handle_event("validate", %{"task" => params}, socket) do
    changeset =
      %Task{}
      |> Task.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :task))}
  end

  @impl true
  def handle_event("save", %{"task" => params}, socket) do
    params = normalize_params(params)

    case Tasks.create(params) do
      {:ok, task} ->
        log_created(task.id)

        {:noreply,
         socket
         |> put_flash(:info, "Task created")
         |> push_navigate(to: "/tasks/#{task.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Fix the errors below")
         |> assign(:form, to_form(changeset, as: :task, action: :insert))}
    end
  rescue
    error ->
      Logger.error("TaskLive.New save failed: #{Exception.format(:error, error, __STACKTRACE__)}")

      {:noreply,
       put_flash(
         socket,
         :error,
         "Save failed: #{Exception.message(error)}. Try again or refresh the page."
       )}
  end

  @impl true
  def handle_event("update_group_description", %{"group_description" => text}, socket) do
    {:noreply, assign(socket, :group_description, text)}
  end

  @impl true
  def handle_event("generate_task_group", params, socket) do
    form = socket.assigns.form

    description =
      params
      |> Map.get("group_description", socket.assigns.group_description)
      |> to_string()
      |> String.trim()

    if description == "" do
      {:noreply, put_flash(socket, :error, "Enter a description for the overnight task group")}
    else
      parent = self()

      local_only = form[:local_only].value in [true, "true"]
      assigned_agent = blank_to_nil(form[:assigned_agent].value)

      Elixir.Task.start(fn ->
        result =
          TaskGroups.generate_from_description(description,
            title: form[:title].value,
            project_path: blank_to_nil(form[:project_path].value),
            workspace_mode: form[:workspace_mode].value || "isolated",
            priority: parse_priority(form[:priority].value),
            local_only: local_only,
            assigned_agent: assigned_agent
          )

        send(parent, {:task_group_done, result})
      end)

      {:noreply,
       socket
       |> assign(:group_busy, true)
       |> assign(:llm_hint, "Generating task group with Ollama…")}
    end
  end

  @impl true
  def handle_info({:task_group_done, {:ok, group, tasks}}, socket) do
    count = length(tasks)
    local_only = socket.assigns.form[:local_only].value in [true, "true"]
    dispatch = if local_only, do: "local-only (Ollama)", else: "Cursor"

    {:noreply,
     socket
     |> assign(:group_busy, false)
     |> assign(:llm_hint, "Created group ##{group.id} with #{count} #{dispatch} tasks")
     |> push_navigate(to: "/task-groups/#{group.id}")}
  end

  @impl true
  def handle_info({:task_group_done, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:group_busy, false)
     |> assign(:llm_hint, "Task group failed: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("classify", %{"task" => params}, socket) do
    description = "#{params["title"]}\n#{params["body"]}"

    parent = self()

    Elixir.Task.start(fn ->
      result = Ollama.classify_difficulty(description)
      send(parent, {:classify_done, result})
    end)

    {:noreply,
     socket
     |> assign(:llm_busy, true)
     |> assign(:llm_hint, "Classifying with Ollama…")}
  end

  @impl true
  def handle_event(event, params, socket) do
    Logger.warning("TaskLive.New unhandled event=#{event} params=#{inspect(params)}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:classify_done, {:ok, text}}, socket) do
    {:noreply, assign(socket, llm_busy: false, llm_hint: text)}
  end

  @impl true
  def handle_info({:classify_done, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       llm_busy: false,
       llm_hint: "Ollama error: #{Exception.message(normalize_error(reason))}"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">New task</p>
            <h1 class="hero-title">Create task</h1>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card form-card">
        <.form for={@form} id="task-form" action="/tasks" method="post">
          <div class="form-grid">
            <label>
              <span>Title</span>
              <input type="text" name={@form[:title].name} value={@form[:title].value} required />
              <span :for={msg <- @form[:title].errors} class="field-error"><%= msg %></span>
            </label>
            <label>
              <span>Priority (1–4)</span>
              <input type="number" name={@form[:priority].name} value={@form[:priority].value} min="1" max="4" />
            </label>
            <label class="form-span-all">
              <span>Project folder</span>
              <input
                type="text"
                name={@form[:project_path].name}
                value={@form[:project_path].value}
                placeholder="C:/GitHub/my-app (leave empty for Symphony default)"
              />
              <span class="section-copy">Git branch/commit is read from this folder when you save.</span>
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
            <label class="form-span-all">
              <span>Description</span>
              <textarea name={@form[:body].name} rows="8">{@form[:body].value}</textarea>
            </label>
            <label>
              <span>Status</span>
              <select name={@form[:status].name}>
                <option :for={s <- Task.statuses()} value={s} selected={@form[:status].value == s}>
                  <%= s %>
                </option>
              </select>
            </label>
            <label>
              <span>Assigned agent</span>
              <input
                type="text"
                name={@form[:assigned_agent].name}
                value={@form[:assigned_agent].value}
                placeholder="cursor"
              />
            </label>
            <label class="form-span-all dispatch-option">
              <input type="checkbox" name="dispatch_immediately" value="true" />
              <span>Dispatch immediately (skip queue)</span>
            </label>
            <label class="form-span-all dispatch-option">
              <input
                type="checkbox"
                name={@form[:local_only].name}
                value="true"
                checked={@form[:local_only].value in [true, "true"]}
              />
              <span>Local only (Ollama — never Cursor/cursor-agent)</span>
            </label>
          </div>
          <p class="section-copy form-span-all">
            Tasks join the queue by default. Click <strong>Go</strong> on the dashboard to process them in order.
          </p>
          <div class="form-actions">
            <button type="submit">Create task</button>
            <button type="button" class="secondary" phx-click="classify" disabled={@llm_busy}>
              Classify with Ollama
            </button>
          </div>
        </.form>
        <p :if={@llm_hint} class="llm-box"><%= @llm_hint %></p>
      </section>

      <section class="section-card form-card">
        <h2 class="section-title">Generate task group</h2>
        <p class="section-copy">
          Uses Ollama to split a large task into smaller subtasks. With <strong>Local only</strong> checked above,
          children run via Ollama only; otherwise they use Cursor/cursor-agent like a normal task.
          Project folder, workspace mode, and assigned agent above apply to every child task.
        </p>
        <.form for={@form} id="task-group-form" phx-submit="generate_task_group">
          <label class="form-span-all">
            <span>Parent task description</span>
            <textarea
              name="group_description"
              rows="6"
              phx-change="update_group_description"
              phx-debounce="300"
            ><%= @group_description %></textarea>
          </label>
          <div class="form-actions">
            <button type="submit" class="secondary" disabled={@group_busy || @llm_busy}>
              Generate task group
            </button>
          </div>
        </.form>
      </section>
    </section>
    """
  end

  defp workspace_mode_label("isolated"), do: "Isolated copy (TASK-N folder, no .git)"
  defp workspace_mode_label("linked"), do: "Linked (work directly in project folder)"
  defp workspace_mode_label(other), do: other

  defp parse_priority(nil), do: 3
  defp parse_priority(""), do: 3

  defp parse_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in 1..4 -> int
      _ -> 3
    end
  end

  defp parse_priority(value) when is_integer(value), do: value
  defp parse_priority(_), do: 3

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{__struct__: _} = err), do: Exception.message(err)
  defp format_error(reason), do: inspect(reason)

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
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp log_created(task_id) do
    Tasks.log_event!(task_id, "created", "Task created from dashboard")
  rescue
    error ->
      Logger.warning("task create log_event failed: #{inspect(error)}")
  end

  defp normalize_error(%{__struct__: _} = err), do: err
  defp normalize_error(reason), do: RuntimeError.exception(inspect(reason))
end
