defmodule SymphonyElixirWeb.TodoLive.New do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Todos
  alias SymphonyElixir.Todos.TodoItem
  import SymphonyElixirWeb.Components.Nav
  import SymphonyElixirWeb.TodoLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    changeset = TodoItem.changeset(%TodoItem{}, %{status: "queued"})

    {:ok,
     socket
     |> assign(:page, :todos)
     |> assign(:form, to_form(changeset, as: :todo))}
  end

  @impl true
  def handle_event("validate", %{"todo" => params}, socket) do
    changeset =
      %TodoItem{}
      |> TodoItem.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :todo))}
  end

  @impl true
  def handle_event("save", %{"todo" => params}, socket) do
    case Todos.create(normalize_params(params)) do
      {:ok, todo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Todo created")
         |> push_navigate(to: "/todos/#{todo.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Fix the errors below")
         |> assign(:form, to_form(changeset, as: :todo, action: :insert))}
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
            <h1 class="hero-title">New todo</h1>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <.todo_form form={@form} submit_label="Create todo" />
        <p class="section-copy"><a href="/todos">← Back to todos</a></p>
      </section>
    </section>
    """
  end
end
