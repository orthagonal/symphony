defmodule SymphonyElixirWeb.TodoLive.Show do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Todos
  alias SymphonyElixir.Todos.TodoItem
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.TodoLive.FormHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    todo = Todos.get!(String.to_integer(id))
    changeset = TodoItem.changeset(todo, form_attrs(todo))

    {:ok,
     socket
     |> assign(:page, :todos)
     |> assign(:todo, todo)
     |> assign(:form, to_form(changeset, as: :todo))
     |> assign(:link_draft, "")
     |> assign(:checklist_draft, "")}
  end

  @impl true
  def handle_event("validate", %{"todo" => params}, socket) do
    changeset =
      socket.assigns.todo
      |> TodoItem.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :todo))}
  end

  @impl true
  def handle_event("save", %{"todo" => params}, socket) do
    case Todos.update(socket.assigns.todo, normalize_params(params)) do
      {:ok, todo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Todo saved")
         |> assign(:todo, todo)
         |> assign(:form, to_form(TodoItem.changeset(todo, form_attrs(todo)), as: :todo))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Fix the errors below")
         |> assign(:form, to_form(changeset, as: :todo, action: :update))}
    end
  end

  @impl true
  def handle_event("update_link_draft", %{"link_draft" => value}, socket) do
    {:noreply, assign(socket, :link_draft, value)}
  end

  @impl true
  def handle_event("add_link", %{"link_draft" => value}, socket) do
    {:noreply, apply_link(socket, value)}
  end

  @impl true
  def handle_event("blur_link", params, socket) do
    {:noreply, apply_link(socket, link_value(params))}
  end

  @impl true
  def handle_event("remove_link", %{"index" => index}, socket) do
    case Todos.remove_link_at(socket.assigns.todo, String.to_integer(index)) do
      {:ok, todo} ->
        {:noreply, assign(socket, :todo, todo)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove link")}
    end
  end

  @impl true
  def handle_event("update_checklist_draft", %{"checklist_draft" => value}, socket) do
    {:noreply, assign(socket, :checklist_draft, value)}
  end

  @impl true
  def handle_event("add_checklist_item", %{"checklist_draft" => value}, socket) do
    {:noreply, apply_checklist_item(socket, value)}
  end

  @impl true
  def handle_event("blur_checklist", params, socket) do
    {:noreply, apply_checklist_item(socket, checklist_value(params))}
  end

  @impl true
  def handle_event("toggle_checklist_item", %{"index" => index}, socket) do
    case Todos.toggle_checklist_item(socket.assigns.todo, String.to_integer(index)) do
      {:ok, todo} ->
        {:noreply, assign(socket, :todo, todo)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update checklist item")}
    end
  end

  @impl true
  def handle_event("remove_checklist_item", %{"index" => index}, socket) do
    case Todos.remove_checklist_item_at(socket.assigns.todo, String.to_integer(index)) do
      {:ok, todo} ->
        {:noreply, assign(socket, :todo, todo)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove checklist item")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Admin</p>
            <h1 class="hero-title">TODO-<%= @todo.id %></h1>
            <p class="hero-copy">Created <%= format_datetime(@todo.inserted_at) %></p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <.todo_form form={@form} submit_label="Save changes" />

        <div class="todo-links-panel">
          <h2 class="section-title">Links</h2>
          <p class="section-copy">Paste a URL below and press Enter (or click away) to add it. Click × to remove.</p>

          <ul :if={(@todo.links || []) != []} class="todo-link-list">
            <li :for={{url, index} <- Enum.with_index(@todo.links)} class="todo-link-row">
              <a href={url} target="_blank" rel="noopener noreferrer"><%= url %></a>
              <button
                type="button"
                class="todo-link-remove"
                phx-click="remove_link"
                phx-value-index={index}
                aria-label="Remove link"
              >
                ×
              </button>
            </li>
          </ul>

          <form
            id="todo-link-form"
            class="todo-link-form"
            phx-change="update_link_draft"
            phx-submit="add_link"
          >
            <input
              type="text"
              class="todo-link-paste"
              name="link_draft"
              placeholder="Paste a link here…"
              value={@link_draft}
              autocomplete="off"
              phx-blur="blur_link"
            />
          </form>
        </div>

        <div class="todo-checklist-panel">
          <h2 class="section-title">Checklist</h2>
          <p class="section-copy">Type an item below and press Enter (or click away) to add it. Check items off or click × to remove.</p>

          <ul :if={(@todo.checklist || []) != []} class="todo-checklist-list">
            <li :for={{item, index} <- Enum.with_index(@todo.checklist)} class="todo-checklist-row">
              <label class="todo-checklist-label">
                <input
                  type="checkbox"
                  checked={item["done"] in [true, "true", 1, "1"]}
                  phx-click="toggle_checklist_item"
                  phx-value-index={index}
                />
                <span class={if item["done"] in [true, "true", 1, "1"], do: "todo-checklist-text todo-checklist-text-done", else: "todo-checklist-text"}>
                  <%= item["text"] %>
                </span>
              </label>
              <button
                type="button"
                class="todo-checklist-remove"
                phx-click="remove_checklist_item"
                phx-value-index={index}
                aria-label="Remove checklist item"
              >
                ×
              </button>
            </li>
          </ul>

          <form
            id="todo-checklist-form"
            class="todo-checklist-form"
            phx-change="update_checklist_draft"
            phx-submit="add_checklist_item"
          >
            <input
              type="text"
              class="todo-checklist-add"
              name="checklist_draft"
              placeholder="Add a checklist item…"
              value={@checklist_draft}
              autocomplete="off"
              phx-blur="blur_checklist"
            />
          </form>
        </div>

        <p class="section-copy"><a href="/todos">← Back to todos</a></p>
      </section>
    </section>
    """
  end

  defp link_value(%{"link_draft" => value}), do: value
  defp link_value(%{"value" => value}), do: value
  defp link_value(_), do: ""

  defp checklist_value(%{"checklist_draft" => value}), do: value
  defp checklist_value(%{"value" => value}), do: value
  defp checklist_value(_), do: ""

  defp apply_link(socket, value) do
    url = value |> to_string() |> String.trim()

    if url == "" do
      socket
    else
      case Todos.append_link(socket.assigns.todo, url) do
        {:ok, todo} ->
          socket |> assign(:todo, todo) |> assign(:link_draft, "")

        {:error, _} ->
          put_flash(socket, :error, "Could not add link")
      end
    end
  end

  defp apply_checklist_item(socket, value) do
    text = value |> to_string() |> String.trim()

    if text == "" do
      socket
    else
      case Todos.append_checklist_item(socket.assigns.todo, text) do
        {:ok, todo} ->
          socket |> assign(:todo, todo) |> assign(:checklist_draft, "")

        {:error, _} ->
          put_flash(socket, :error, "Could not add checklist item")
      end
    end
  end

  defp form_attrs(%TodoItem{} = todo) do
    %{
      "title" => todo.title,
      "notes" => todo.notes,
      "status" => todo.status,
      "due_at" => format_due_for_input(todo.due_at),
      "task_group_id" => todo.task_group_id,
      "task_id" => todo.task_id
    }
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
