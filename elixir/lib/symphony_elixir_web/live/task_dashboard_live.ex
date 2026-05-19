defmodule SymphonyElixirWeb.TaskDashboardLive do
  @moduledoc """
  Local task board for the agent manager dashboard.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{TaskQueue, Tasks}
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.Components.TaskBadges

  @pubsub SymphonyElixir.PubSub
  @queue_topic "task_queue"
  @refresh_ms 4_000
  @columns ~w(queued waiting assigned running blocked review done failed cancelled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
      Phoenix.PubSub.subscribe(@pubsub, @queue_topic)
    end

    {:ok,
     socket
     |> assign(:page, :dashboard)
     |> assign(:columns, @columns)
     |> assign(:queue, TaskQueue.status())
     |> refresh_tasks()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh_tasks(socket)}
  end

  @impl true
  def handle_info({_event, _payload}, socket) do
    {:noreply, assign(socket, :queue, TaskQueue.status()) |> refresh_tasks()}
  end

  @impl true
  def handle_event("go_queue", _params, socket) do
    TaskQueue.go()
    {:noreply, assign(socket, :queue, TaskQueue.status()) |> refresh_tasks()}
  end

  @impl true
  def handle_event("stop_queue", _params, socket) do
    TaskQueue.stop_processing()
    {:noreply, assign(socket, :queue, TaskQueue.status())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Agent Manager</p>
            <h1 class="hero-title">Local tasks</h1>
            <p class="hero-copy">
              SQLite-backed tasks for phone-friendly control. Qwen3 summarizes; Cursor Composer implements.
            </p>
          </div>
          <div class="hero-actions">
            <.agent_nav current={@page} />
            <button
              :if={@queue.status != :running}
              type="button"
              class="dispatch-button"
              phx-click="go_queue"
            >
              Go
            </button>
            <button
              :if={@queue.status == :running}
              type="button"
              class="secondary"
              phx-click="stop_queue"
            >
              Stop queue
            </button>
            <a class="button-link" href="/tasks/new">New task</a>
          </div>
        </div>
      </header>

      <p class="section-copy queue-status">
        Queue: <strong>{@queue.status}</strong>
        · queued: {Map.get(@counts, "queued", 0)}
        <span :if={@queue.status == :running}>
          · running TASK-{@queue.waiting_task_id} · {@queue.remaining} remaining
        </span>
      </p>

      <div class="metric-grid">
        <article :for={status <- @columns} class="metric-card">
          <p class="metric-label"><%= status %></p>
          <p class="metric-value"><%= Map.get(@counts, status, 0) %></p>
        </article>
      </div>

      <div class="task-board">
        <section :for={status <- @columns} class="task-column">
          <h2 class="task-column-title"><%= status %></h2>
          <div class="task-column-list">
            <article :for={task <- Map.get(@by_status, status, [])} class="task-card">
              <a class="task-card-link" href={"/tasks/#{task.id}"}>
                <p class="task-card-id">TASK-<%= task.id %></p>
                <h3 class="task-card-title"><%= task.title %></h3>
                <p :if={task.body} class="task-card-body"><%= truncate(task.body, 120) %></p>
                <.task_badges :if={task.local_only or task.task_group_id} task={task} class="task-card-badges" />
                <p class="task-card-meta">
                  <%= if task.assigned_agent, do: task.assigned_agent, else: "unassigned" %>
                </p>
              </a>
            </article>
            <p :if={Map.get(@by_status, status, []) == []} class="empty-state">None</p>
          </div>
        </section>
      </div>
    </section>
    """
  end

  defp refresh_tasks(socket) do
    tasks = Tasks.list_all()
    counts = Tasks.counts_by_status()

    by_status =
      @columns
      |> Enum.map(fn status -> {status, Enum.filter(tasks, &(&1.status == status))} end)
      |> Map.new()

    socket
    |> assign(:tasks, tasks)
    |> assign(:counts, counts)
    |> assign(:by_status, by_status)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end

  defp truncate(nil, _), do: ""

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end
end
