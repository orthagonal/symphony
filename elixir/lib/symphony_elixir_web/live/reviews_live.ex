defmodule SymphonyElixirWeb.ReviewsLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Reviews, Tasks}
  import SymphonyElixirWeb.Components.Nav

  @pubsub SymphonyElixir.PubSub
  @reviews_topic "reviews"
  @queue_topic "task_queue"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @reviews_topic)
      Phoenix.PubSub.subscribe(@pubsub, @queue_topic)
    end

    {:ok,
     socket
     |> assign(:page, :reviews)
     |> refresh()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_id, parse_id(id))
     |> refresh()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_id, nil) |> refresh()}
  end

  @impl true
  def handle_event("toggle_item", %{"ticket_id" => ticket_id, "item_id" => item_id}, socket) do
    Reviews.toggle_checklist_item!(String.to_integer(ticket_id), item_id)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("review_done", %{"task_id" => task_id}, socket) do
    id = String.to_integer(task_id)

    _ = Tasks.update_status!(id, "done")
    _ = Tasks.log_event!(id, "status", "Marked done from Reviews screen")
    _ = Reviews.complete_open_ticket_for_task!(id)

    {:noreply,
     socket
     |> put_flash(:info, "Task TASK-#{id} marked done.")
     |> push_patch(to: "/reviews")
     |> assign(:selected_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("review_failed", %{"task_id" => task_id}, socket) do
    id = String.to_integer(task_id)

    _ = Tasks.update_status!(id, "failed")
    _ = Tasks.log_event!(id, "status", "Marked failed from Reviews screen")
    _ = Reviews.complete_open_ticket_for_task!(id)

    {:noreply,
     socket
     |> put_flash(:info, "Task TASK-#{id} marked failed.")
     |> push_patch(to: "/reviews")
     |> assign(:selected_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("resubmit", params, socket) do
    task_id =
      case Map.get(params, "task_id") do
        id when is_binary(id) -> String.to_integer(id)
      end

    notes = params |> Map.get("notes", "") |> to_string()

    _ = Tasks.resubmit_from_review!(task_id, notes)

    {:noreply,
     socket
     |> put_flash(:info, "TASK-#{task_id} returned to queue with your notes.")
     |> push_patch(to: "/reviews")
     |> assign(:selected_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_info({_event, _payload}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Human gate</p>
            <h1 class="hero-title">Reviews</h1>
            <p class="hero-copy">
              Tasks enter review after an agent run succeeds or fails. Approve (Done), reject (Failed), or send back to the queue with notes (Resubmit).
            </p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <div class="review-layout">
        <aside class="review-list section-card">
          <ul class="review-ticket-list">
            <li :for={task <- @tasks} class="review-ticket-list-item">
              <a
                class={if task.id == @selected_id, do: "review-link-active", else: "review-link"}
                href={"/reviews/#{task.id}"}
              >
                <span class="review-status-pill state-badge-review">review</span>
                <%= task.title %>
              </a>
            </li>
          </ul>
          <p :if={@tasks == []} class="empty-state">No tasks in review.</p>
        </aside>

        <section :if={@selected} class="section-card review-detail">
          <h2 class="section-title"><%= @selected.title %></h2>
          <p class="section-copy">
            <span class="state-badge state-badge-review"><%= @selected.status %></span>
            ·
            <a href={"/tasks/#{@selected.id}"}>Open TASK-<%= @selected.id %></a>
          </p>

          <h3 class="section-title">Task description</h3>
          <pre class="task-body"><%= @selected.body || "No description." %></pre>

          <div :if={@selected.review_ticket} class="review-checklist-wrap">
            <h3 class="section-title">Review ticket checklist</h3>
            <p :if={@selected.review_ticket.summary} class="llm-box"><%= @selected.review_ticket.summary %></p>

            <ul class="review-checklist">
              <li
                :for={item <- @selected.review_ticket.checklist || []}
                class="review-checklist-item"
              >
                <label class="dispatch-option">
                  <input
                    type="checkbox"
                    checked={item["done"]}
                    phx-click="toggle_item"
                    phx-value-ticket_id={@selected.review_ticket.id}
                    phx-value-item_id={item["id"]}
                  />
                  <span class={if item["done"], do: "review-done", else: ""}><%= item["label"] %></span>
                </label>
              </li>
            </ul>
          </div>

          <div class="form-actions review-action-row">
            <button type="button" phx-click="review_done" phx-value-task_id={@selected.id}>
              Done
            </button>
            <button type="button" class="danger" phx-click="review_failed" phx-value-task_id={@selected.id}>
              Failed
            </button>
          </div>

          <div class="resubmit-box">
            <h3 class="section-title">Resubmit to agent</h3>
            <p class="section-copy">
              Prepends your notes plus the review ticket summary/checklist to the task body and sets status to <strong>queued</strong>.
            </p>
            <form phx-submit="resubmit" class="resubmit-form">
              <input type="hidden" name="task_id" value={@selected.id} />
              <textarea name="notes" rows="6" placeholder="Advice for the agent…"></textarea>
              <div class="form-actions">
                <button type="submit" class="secondary">Resubmit</button>
              </div>
            </form>
          </div>
        </section>

        <section :if={!@selected and @selected_id} class="section-card">
          <p class="empty-state">That task is not in review (or does not exist).</p>
        </section>

        <section :if={!@selected_id} class="section-card">
          <p class="empty-state">Select a task.</p>
        </section>
      </div>
    </section>
    """
  end

  defp refresh(socket) do
    tasks = Tasks.list_in_review()
    selected_id = socket.assigns[:selected_id]

    selected =
      if selected_id do
        Enum.find(tasks, &(&1.id == selected_id))
      end

    assign(socket, tasks: tasks, selected: selected)
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
