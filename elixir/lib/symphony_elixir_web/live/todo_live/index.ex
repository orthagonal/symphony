defmodule SymphonyElixirWeb.TodoLive.Index do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Todos
  import SymphonyElixirWeb.Components.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page, :todos)
     |> assign(:todos, Todos.list_all())}
  end

  @impl true
  def handle_event("delete", %{"todo_id" => id}, socket) do
    _ = Todos.delete!(String.to_integer(id))

    {:noreply,
     socket
     |> put_flash(:info, "Todo deleted")
     |> assign(:todos, Todos.list_all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Admin</p>
            <h1 class="hero-title">Todos</h1>
            <p class="hero-copy">
              Track work with optional links to task groups and individual tasks. Paste URLs and manage checklists on the detail page.
            </p>
            <p class="section-actions">
              <a class="button-link" href="/todos/new">New todo</a>
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <p :if={@todos == []} class="section-copy">No todos yet. Create one to get started.</p>
        <div class="task-column-list">
          <article :for={todo <- @todos} class="task-card todo-card">
            <a class="task-card-link" href={"/todos/#{todo.id}"}>
              <p class="task-card-id">TODO-<%= todo.id %></p>
              <h3 class="task-card-title"><%= todo.title %></h3>
              <p :if={todo.notes && todo.notes != ""} class="task-card-body">
                <%= String.slice(todo.notes, 0, 120) %>
              </p>
              <p class="task-card-meta">
                <span class={todo_status_class(todo.status)}><%= todo_status_label(todo.status) %></span>
                · Created <%= format_datetime(todo.inserted_at) %>
                <%= if todo.due_at do %>
                  · Due <%= format_datetime(todo.due_at) %>
                <% end %>
              </p>
              <p :if={todo.task_group_id || todo.task_id} class="task-card-meta">
                <%= if todo.task_group_id do %>
                  <a href={"/task-groups/#{todo.task_group_id}"} onclick="event.stopPropagation();">Group #<%= todo.task_group_id %></a>
                <% end %>
                <%= if todo.task_group_id && todo.task_id do %>
                  ·
                <% end %>
                <%= if todo.task_id do %>
                  <a href={"/tasks/#{todo.task_id}"} onclick="event.stopPropagation();">Task #<%= todo.task_id %></a>
                <% end %>
              </p>
              <p :if={length(todo.links || []) > 0} class="task-card-meta">
                <%= length(todo.links) %> link<%= if length(todo.links) == 1, do: "", else: "s" %>
              </p>
              <p :if={length(todo.checklist || []) > 0} class="task-card-meta">
                <%= checklist_progress(todo.checklist) %>
              </p>
            </a>
            <form class="todo-card-delete" phx-submit="delete">
              <input type="hidden" name="todo_id" value={todo.id} />
              <button type="submit" class="secondary danger-button">Delete</button>
            </form>
          </article>
        </div>
      </section>
    </section>
    """
  end

  defp todo_status_class("finished"), do: "state-badge state-badge-active"
  defp todo_status_class("blocked"), do: "state-badge state-badge-danger"
  defp todo_status_class("needFinishing"), do: "state-badge state-badge-warning"
  defp todo_status_class(_), do: "state-badge"

  defp todo_status_label("needFinishing"), do: "Need finishing"
  defp todo_status_label(status), do: status

  defp checklist_progress(checklist) do
    total = length(checklist)
    done = Enum.count(checklist, &(&1["done"] in [true, "true", 1, "1"]))
    "#{done}/#{total} checklist item#{if total == 1, do: "", else: "s"} done"
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
