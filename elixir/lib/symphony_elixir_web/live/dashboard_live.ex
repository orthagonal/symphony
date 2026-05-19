defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony (runtime + Cursor Agent CLI account).
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.Components.Nav

  alias SymphonyElixir.Cursor
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @cursor_refresh_ms 45_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, :cursor)
      |> assign(:cursor_account, unloaded_cursor_account())
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      send(self(), :refresh_cursor_account)
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
  def handle_info(:refresh_cursor_account, socket) do
    schedule_cursor_refresh()

    {:noreply,
     socket
     |> assign(:cursor_account, load_cursor_account())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Cursor observability
            </p>
            <h1 class="hero-title">
              Operations dashboard
            </h1>
            <p class="hero-copy">
              Cursor Agent CLI account (your logged-in plan and default model). Running / retrying counts and Codex-derived token totals still reflect the Linear orchestrator snapshot when enabled.
            </p>
          </div>

          <div class="status-stack-with-nav">
            <.agent_nav current={@page} />
            <div class="status-stack">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Offline
              </span>
            </div>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Orchestrator sessions marked active.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Orchestrator issues in retry backoff.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Cursor subscription</p>
            <p class="metric-value">
              <%= cursor_metric_value(@cursor_account, :tier) %>
            </p>
            <p class="metric-detail numeric">
              <%= cursor_metric_detail(@cursor_account, :tier) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Cursor default model</p>
            <p class="metric-value text-metric-value">
              <%= cursor_metric_value(@cursor_account, :model) %>
            </p>
            <p class="metric-detail numeric">
              <%= cursor_metric_detail(@cursor_account, :model) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Codex token totals</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Codex orchestration runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Wall time across Codex-backed sessions plus active runs.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Upstream Codex rate limits</h2>
              <p class="section-copy">From the Symphony orchestrator (OpenAI Codex app-server path), not Cursor.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Last Codex activity</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp unloaded_cursor_account do
    %{loaded: false, ok: nil, error: nil, data: nil}
  end

  defp load_cursor_account do
    case Cursor.account_snapshot() do
      {:ok, data} ->
        %{loaded: true, ok: true, error: nil, data: data}

      {:error, reason} ->
        %{loaded: true, ok: false, error: cursor_account_error_text(reason), data: nil}
    end
  end

  defp cursor_account_error_text(:cursor_agent_missing),
    do: "cursor-agent CLI not installed or not on PATH (set CURSOR_AGENT_COMMAND)"

  defp cursor_account_error_text(:empty_agent_output),
    do: "cursor-agent returned empty output"

  defp cursor_account_error_text({:cursor_agent_cmd_failed, code, detail}),
    do: "cursor-agent failed (#{code}): #{shorten_agent_text(detail, 240)}"

  defp cursor_account_error_text({:invalid_json, snippet}),
    do: "invalid cursor-agent JSON: #{shorten_agent_text(snippet, 160)}"

  defp cursor_account_error_text(other),
    do: inspect(other)

  defp shorten_agent_text(text, max) when is_binary(text) do
    compact = String.replace(text, ~r/\s+/u, " ")

    if String.length(compact) <= max do
      compact
    else
      String.slice(compact, 0, max) <> "…"
    end
  end

  defp shorten_agent_text(_other, _max), do: ""

  defp cursor_metric_value(%{loaded: false}, _field), do: "…"

  defp cursor_metric_value(%{ok: false}, :tier), do: "Unavailable"
  defp cursor_metric_value(%{ok: false}, :model), do: "—"

  defp cursor_metric_value(%{ok: true, data: %{subscription_tier: tier}}, :tier)
       when is_binary(tier) and tier != "",
       do: tier

  defp cursor_metric_value(%{ok: true, data: _}, :tier), do: "—"

  defp cursor_metric_value(%{ok: true, data: %{model: model}}, :model)
       when is_binary(model) and model != "",
       do: model

  defp cursor_metric_value(%{ok: true, data: _}, :model), do: "—"

  defp cursor_metric_detail(%{loaded: false}, _), do: "Loading Cursor account …"

  defp cursor_metric_detail(%{ok: false, error: msg}, _), do: msg

  defp cursor_metric_detail(%{ok: true, data: data}, :tier), do: cursor_tier_secondary(data)

  defp cursor_metric_detail(%{ok: true, data: data}, :model),
    do: cursor_model_secondary(data)

  defp cursor_tier_secondary(data) when is_map(data) do
    auth = if Map.get(data, :authenticated), do: "signed in", else: "not signed in"

    line =
      [auth, Map.get(data, :email), cli_version_fragment(Map.get(data, :cli_version))]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    if line == "", do: auth, else: line
  end

  defp cursor_tier_secondary(_), do: ""

  defp cli_version_fragment(v) when is_binary(v) and v != "", do: "CLI #{v}"
  defp cli_version_fragment(_), do: nil

  defp cursor_model_secondary(%{os_platform: os, shell: shell}) do
    case Enum.join(Enum.reject([os, shell], &(&1 in [nil, ""])), " · ") do
      "" -> "From cursor-agent about"
      platform_line -> platform_line
    end
  end

  defp cursor_model_secondary(_), do: "From cursor-agent about"

  defp schedule_cursor_refresh do
    Process.send_after(self(), :refresh_cursor_account, @cursor_refresh_ms)
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
