defmodule SymphonyElixirWeb.TaskGroupLive.Show do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.TaskGroups
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.Components.TaskBadges

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {group_id, ""} ->
        {:ok,
         socket
         |> assign(:page, :task_groups)
         |> assign(:group, TaskGroups.get_with_tasks!(group_id))}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid group id")
         |> push_navigate(to: "/task-groups")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">GROUP-<%= @group.id %></p>
            <h1 class="hero-title"><%= @group.title %></h1>
            <p class="hero-copy">
              <span class="state-badge"><%= @group.status %></span>
              · <%= length(@group.tasks) %> tasks
              <.local_only_badge />
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <h2 class="section-title">Description</h2>
        <pre class="task-body"><%= @group.description || "(none)" %></pre>
      </section>

      <section class="section-card">
        <h2 class="section-title">Tasks in this group</h2>
        <div class="task-column-list">
          <article :for={task <- @group.tasks} class="task-card">
            <a class="task-card-link" href={"/tasks/#{task.id}"}>
              <p class="task-card-id">TASK-<%= task.id %></p>
              <h3 class="task-card-title"><%= task.title %></h3>
              <p class="task-card-meta"><%= task.status %></p>
              <.task_badges :if={task.local_only or task.task_group_id} task={task} class="task-card-badges" />
            </a>
          </article>
        </div>
        <p :if={@group.tasks == []} class="section-copy">No tasks linked to this group.</p>
      </section>

      <p class="section-copy">
        <a href="/task-groups">← All task groups</a>
      </p>
    </section>
    """
  end
end
