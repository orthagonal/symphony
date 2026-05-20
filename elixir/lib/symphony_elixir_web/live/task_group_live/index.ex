defmodule SymphonyElixirWeb.TaskGroupLive.Index do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.TaskGroups
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.Components.TaskBadges

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page, :task_groups)
     |> assign(:groups, TaskGroups.list_all())
     |> assign(:counts, TaskGroups.task_counts())
     |> assign(:local_only_groups, TaskGroups.local_only_group_ids())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Overnight</p>
            <h1 class="hero-title">Task groups</h1>
            <p class="hero-copy">
              Batched subtasks generated from a parent description (Ollama split; local-only or Cursor per group).
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <p :if={@groups == []} class="section-copy">
          No task groups yet. Use <strong>Generate task group</strong> on the New task page.
        </p>
        <div class="task-column-list">
          <article :for={group <- @groups} class="task-card">
            <a class="task-card-link" href={"/task-groups/#{group.id}"}>
              <p class="task-card-id">GROUP-<%= group.id %></p>
              <h3 class="task-card-title"><%= group.title %></h3>
              <p class="task-card-body"><%= String.slice(group.description || "", 0, 120) %></p>
              <p class="task-card-meta">
                <%= Map.get(@counts, group.id, 0) %> tasks · <%= group.status %>
              </p>
              <span :if={MapSet.member?(@local_only_groups, group.id)} class="task-card-badges">
                <.local_only_badge />
              </span>
            </a>
          </article>
        </div>
      </section>
    </section>
    """
  end
end
