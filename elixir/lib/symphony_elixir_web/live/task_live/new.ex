defmodule SymphonyElixirWeb.TaskLive.New do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  require Logger

  alias SymphonyElixir.{Ollama, Tasks}
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
     |> assign(:llm_hint, nil)}
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
    </section>
    """
  end

  defp workspace_mode_label("isolated"), do: "Isolated copy (TASK-N folder, no .git)"
  defp workspace_mode_label("linked"), do: "Linked (work directly in project folder)"
  defp workspace_mode_label(other), do: other

  defp normalize_params(params) when is_map(params) do
    params
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
