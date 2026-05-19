defmodule SymphonyElixirWeb.SettingsLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.Components.Nav

  alias SymphonyElixir.{Config, Ollama, Tasks}

  @impl true
  def mount(_params, _session, socket) do
    settings =
      case Config.settings() do
        {:ok, s} -> s
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:page, :settings)
     |> assign(:settings, settings)
     |> assign(:db_path, Tasks.database_path())
     |> assign(:ollama_url, Ollama.base_url())
     |> assign(:ollama_model, Ollama.model())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Settings</p>
            <h1 class="hero-title">Local configuration</h1>
            <p class="hero-copy">Read from WORKFLOW.md / env. Web auth is disabled for now.</p>
          </div>
          <.agent_nav current={@page} />
        </div>
      </header>

      <section class="section-card">
        <h2 class="section-title">Server</h2>
        <dl class="settings-dl">
          <dt>Host</dt>
          <dd><%= server_host(@settings) %></dd>
          <dt>Port</dt>
          <dd><%= server_port(@settings) %></dd>
        </dl>
      </section>

      <section class="section-card">
        <h2 class="section-title">Tracker</h2>
        <dl class="settings-dl">
          <dt>Kind</dt>
          <dd><%= tracker_kind(@settings) %></dd>
          <dt>Database</dt>
          <dd class="mono"><%= @db_path %></dd>
          <dt>Active states</dt>
          <dd><%= active_states(@settings) %></dd>
        </dl>
      </section>

      <section class="section-card">
        <h2 class="section-title">Ollama / Qwen3</h2>
        <dl class="settings-dl">
          <dt>Base URL</dt>
          <dd class="mono"><%= @ollama_url %></dd>
          <dt>Model</dt>
          <dd><%= @ollama_model %></dd>
        </dl>
        <p class="section-copy">
          Set OLLAMA_HOST and OLLAMA_MODEL to override. Installed:
          <%= Enum.join(Ollama.list_installed_models(), ", ") || "none" %>
        </p>
      </section>

      <section class="section-card">
        <h2 class="section-title">Workspace</h2>
        <dl class="settings-dl">
          <dt>Root</dt>
          <dd class="mono"><%= workspace_root(@settings) %></dd>
        </dl>
      </section>
    </section>
    """
  end

  defp server_host(nil), do: "n/a"
  defp server_host(settings), do: settings.server.host || "n/a"

  defp server_port(nil), do: Config.server_port()
  defp server_port(settings), do: settings.server.port || Config.server_port()

  defp tracker_kind(nil), do: "n/a"
  defp tracker_kind(settings), do: settings.tracker.kind || "n/a"

  defp active_states(nil), do: "n/a"

  defp active_states(settings) do
    (settings.tracker.active_states || []) |> Enum.join(", ")
  end

  defp workspace_root(nil), do: "n/a"
  defp workspace_root(settings), do: settings.workspace.root || "n/a"
end
