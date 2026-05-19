defmodule SymphonyElixirWeb.AgentsLive do
  @moduledoc """
  Codex orchestrator status (running / retrying agents).
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.Components.Nav

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, :agents)
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Agents</p>
            <h1 class="hero-title">Codex orchestrator</h1>
            <p class="hero-copy">Live Symphony agent slots (Codex app-server). Local tasks stay queued until status is `running`.</p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <p><%= @payload.error.message %></p>
        </section>
      <% else %>
        <div class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value"><%= @payload.counts.running %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value"><%= @payload.counts.retrying %></p>
          </article>
        </div>

        <section class="section-card">
          <h2 class="section-title">Running</h2>
          <p :if={@payload.running == []} class="empty-state">No Codex agents running.</p>
          <ul :if={@payload.running != []} class="event-log">
            <li :for={entry <- @payload.running}>
              <strong><%= entry.issue_identifier %></strong>
              — <%= entry.state %> — turns <%= entry.turn_count %>
            </li>
          </ul>
        </section>

        <section class="section-card">
          <h2 class="section-title">Retry queue</h2>
          <p :if={@payload.retrying == []} class="empty-state">No retries.</p>
          <ul :if={@payload.retrying != []} class="event-log">
            <li :for={entry <- @payload.retrying}>
              <strong><%= entry.issue_identifier %></strong> attempt <%= entry.attempt %>
            </li>
          </ul>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload, do: Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
