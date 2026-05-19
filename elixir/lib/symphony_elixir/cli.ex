defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)
      :ok = configure_runtime_paths(expanded_path)

      with :ok <- verify_local_sqlite_launcher(expanded_path),
           {:ok, _started_apps} <- deps.ensure_all_started.() do
        :ok
      else
        {:error, message} when is_binary(message) ->
          {:error, message}

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec verify_local_sqlite_launcher(Path.t()) :: :ok | {:error, String.t()}
  defp verify_local_sqlite_launcher(workflow_path) do
    if local_tracker?(workflow_path) and escript_launch?() and not sqlite_runtime_ready?(workflow_path) do
      {:error, escript_sqlite_help_message(workflow_path)}
    else
      :ok
    end
  end

  defp local_tracker?(workflow_path) do
    case SymphonyElixir.Workflow.load(workflow_path) do
      {:ok, %{config: %{"tracker" => %{"kind" => "local"}}}} -> true
      _ -> false
    end
  end

  defp escript_launch? do
    not Code.ensure_loaded?(Mix)
  end

  defp sqlite_runtime_ready?(workflow_path) do
    workflow_dir = Path.dirname(workflow_path)

    try do
      :ok = ensure_exqlite_nif!(workflow_dir)
      {:ok, conn} = Exqlite.Sqlite3.open(":memory:")
      :ok = Exqlite.Sqlite3.close(conn)
      true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp escript_sqlite_help_message(workflow_path) do
    """
    Local SQLite tasks are not available via bin/symphony escript on this machine.

    Run Symphony from the elixir directory with Mix instead:

      mix symphony.run #{workflow_path} --port 4321 --i-understand-that-this-will-be-running-without-the-usual-guardrails

    Then create tasks with:

      mix symphony.task "Your task title"
    """
    |> String.trim()
  end

  @spec configure_runtime_paths(Path.t()) :: :ok
  defp configure_runtime_paths(workflow_path) do
    workflow_dir = Path.dirname(workflow_path)

    priv_candidates = [
      Path.join(workflow_dir, "priv"),
      Path.join(workflow_dir, "_build/dev/lib/symphony_elixir/priv"),
      Path.join(workflow_dir, "_build/escript/lib/symphony_elixir/priv")
    ]

    case Enum.find_value(priv_candidates, &migrations_path_for_priv/1) do
      migrations_path when is_binary(migrations_path) ->
        Application.put_env(:symphony_elixir, :migrations_path, migrations_path)

      _ ->
        :ok
    end

    :ok = ensure_exqlite_nif!(workflow_dir)

    :ok
  end

  defp ensure_exqlite_nif!(workflow_dir) do
    priv_candidates = [
      Path.join(workflow_dir, "_build/dev/lib/exqlite/priv"),
      Path.join(workflow_dir, "_build/escript/lib/exqlite/priv")
    ]

    priv =
      Enum.find_value(priv_candidates, fn candidate ->
        if File.dir?(candidate), do: candidate
      end)

    priv =
      priv ||
        case :code.priv_dir(:exqlite) do
          path when is_binary(path) -> path
          _ -> nil
        end

    if is_binary(priv) do
      prepend_path_env!(priv)
      prepend_code_path!(priv)

      case Application.ensure_all_started(:exqlite) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise "failed to start exqlite: #{inspect(reason)}"
      end
    else
      raise "exqlite priv directory not found; run `mix deps.compile exqlite` from #{workflow_dir}"
    end
  end

  defp prepend_path_env!(directory) do
    existing = System.get_env("PATH", "")
    separator = if String.contains?(existing, ";"), do: ";", else: ":"
    System.put_env("PATH", directory <> separator <> existing)
  end

  defp prepend_code_path!(directory) do
    charlist = String.to_charlist(directory)

    case :code.add_patha(charlist) do
      true -> :ok
      false -> :code.add_path(charlist)
    end
  end

  defp migrations_path_for_priv(priv_dir) do
    path = Path.join(priv_dir, "repo/migrations")

    if File.dir?(path) do
      path
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
