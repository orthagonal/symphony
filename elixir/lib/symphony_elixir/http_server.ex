defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  require Logger

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, Config.server_port())
    host = Keyword.get(opts, :host, server_host())

    cond do
      not is_integer(port) or port <= 0 ->
        Logger.info(
          "HTTP dashboard disabled. Set server.port in WORKFLOW.md or pass --port <number> (for example --port 4321)."
        )

        :ignore

      true ->
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        case parse_host(host) do
          {:ok, ip} ->
            endpoint_opts = [
              server: true,
              http: [ip: ip, port: port],
              url: [host: normalize_host(host)],
              orchestrator: orchestrator,
              snapshot_timeout_ms: snapshot_timeout_ms,
              secret_key_base: endpoint_secret_key_base()
            ]

            endpoint_config =
              :symphony_elixir
              |> Application.get_env(Endpoint, [])
              |> Keyword.merge(endpoint_opts)

            Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

            Logger.info("Observability dashboard listening on #{public_url(host, ip, port)}")

            Endpoint.start_link()

          {:error, reason} ->
            Logger.error(
              "HTTP dashboard disabled; invalid server.host #{inspect(host)}: #{inspect(reason)}"
            )

            :ignore
        end
    end
  end

  defp server_host do
    case Config.settings() do
      {:ok, settings} -> settings.server.host
      _ -> "127.0.0.1"
    end
  end

  defp public_url(host, ip, port) do
    "http://#{public_host(host, ip)}:#{port}/"
  end

  defp public_host(host, ip) do
    cond do
      host in ["0.0.0.0", "::", "[::]", "", nil] ->
        format_ip(ip)

      is_binary(host) ->
        normalize_host(host)

      true ->
        format_ip(ip)
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: to_string(ip)

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp endpoint_secret_key_base do
    case Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)[:secret_key_base] do
      key when is_binary(key) and byte_size(key) >= 64 ->
        key

      _ ->
        Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
    end
  end
end
