defmodule SymphonyElixirWeb.TaskGroupLive.Show do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.TaskGroups
  alias SymphonyElixir.Tasks.Task
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.Components.TaskBadges

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {group_id, ""} ->
        {:ok,
         socket
         |> assign(:page, :task_groups)
         |> assign(:group_id, group_id)
         |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
         |> load_group()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid group id")
         |> push_navigate(to: "/task-groups")}
    end
  end

  @impl true
  def handle_event("set_all_status", %{"status" => status}, socket) do
    group = TaskGroups.update_all_tasks_status!(socket.assigns.group_id, status)
    count = length(group.tasks)

    {:noreply,
     socket
     |> put_flash(:info, "Set #{count} task#{if count == 1, do: "", else: "s"} to #{status}")
     |> assign(:group, group)}
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
              <.local_only_badge :if={group_local_only?(@group.tasks)} />
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <h2 class="section-title">Description</h2>
        <pre class="task-body"><%= @group.description || "(none)" %></pre>

        <p class="section-copy"><strong>Set all tasks in this group</strong></p>
        <p class="section-copy">
          Updates every task in this group to the chosen status (<%= length(@group.tasks) %> task<%= if length(@group.tasks) == 1, do: "", else: "s" %>).
        </p>
        <div class="status-actions">
          <button
            :for={status <- Task.statuses()}
            type="button"
            class="secondary"
            phx-click="set_all_status"
            phx-value-status={status}
          >
            <%= status %>
          </button>
        </div>
        <div class="delete-task-wrap">
          <form
            action={"/task-groups/#{@group.id}/delete"}
            method="post"
            class="delete-task-form"
            onsubmit={"return confirm('Delete GROUP-#{@group.id} and all #{length(@group.tasks)} tasks permanently? This cannot be undone.');"}
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <button type="submit" class="danger">Delete group and tasks</button>
          </form>
        </div>
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

  defp load_group(socket) do
    assign(socket, :group, TaskGroups.get_with_tasks!(socket.assigns.group_id))
  end

  defp group_local_only?(tasks) when is_list(tasks) do
    tasks != [] and Enum.all?(tasks, & &1.local_only)
  end
end
