defmodule SymphonyElixir.Electron.Session do
  @moduledoc """
  GenServer that builds, launches, inspects, and shuts down an Electron app for agent debugging.

  One singleton session is supervised under `SymphonyElixir.Application`. The process stays idle
  until an agent calls `build/1`, `launch/1`, or `build_and_launch/1`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config

  @name __MODULE__
  @default_main_inspect_port 9229
  @default_remote_debug_port 9222
  @default_build_timeout_ms 600_000
  @default_startup_timeout_ms 120_000
  @default_log_tail_lines 50
  @stop_grace_ms 5_000

  @type status :: :idle | :building | :starting | :running | :stopping | :stopped | :crashed

  @type state :: %{
          status: status(),
          game_folder: String.t() | nil,
          game_name: String.t() | nil,
          compile_script: String.t(),
          npm_command: String.t(),
          main_inspect_port: pos_integer(),
          remote_debug_port: pos_integer(),
          build_timeout_ms: pos_integer(),
          startup_timeout_ms: pos_integer(),
          log_dir: String.t(),
          log_path: String.t() | nil,
          port: port() | nil,
          os_pid: non_neg_integer() | nil,
          build_result: map() | nil,
          started_at: DateTime.t() | nil,
          last_exit: map() | nil,
          command_runner: (String.t(), String.t(), keyword() -> {String.t(), non_neg_integer()}),
          port_starter: (String.t(), keyword() -> {:ok, port()} | {:error, term()}),
          http_get: (String.t() -> {:ok, term()} | {:error, term()})
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []), do: GenServer.call(server(opts), {:build, opts})

  @spec launch(keyword()) :: {:ok, map()} | {:error, term()}
  def launch(opts \\ []), do: GenServer.call(server(opts), {:launch, opts})

  @spec build_and_launch(keyword()) :: {:ok, map()} | {:error, term()}
  def build_and_launch(opts \\ []), do: GenServer.call(server(opts), {:build_and_launch, opts})

  @spec status(GenServer.server()) :: map()
  def status(server \\ @name), do: GenServer.call(server, :status)

  @spec tail_log(pos_integer(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def tail_log(lines \\ @default_log_tail_lines, server \\ @name)
      when is_integer(lines) and lines > 0 do
    GenServer.call(server, {:tail_log, lines})
  end

  @spec inspect_targets(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def inspect_targets(server \\ @name), do: GenServer.call(server, :inspect_targets)

  @spec stop(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stop(server \\ @name), do: GenServer.call(server, :stop, @default_build_timeout_ms)

  @impl true
  def init(opts) do
    config = config_snapshot()

    state = %{
      status: :idle,
      game_folder: nil,
      game_name: nil,
      compile_script: config.compile_script,
      npm_command: config.npm_command,
      main_inspect_port: config.main_inspect_port,
      remote_debug_port: config.remote_debug_port,
      build_timeout_ms: config.build_timeout_ms,
      startup_timeout_ms: config.startup_timeout_ms,
      log_dir: config.log_dir,
      log_path: nil,
      port: nil,
      os_pid: nil,
      build_result: nil,
      started_at: nil,
      last_exit: nil,
      command_runner: Keyword.get(opts, :command_runner, &default_command_runner/3),
      port_starter: Keyword.get(opts, :port_starter, &default_port_starter/2),
      http_get: Keyword.get(opts, :http_get, &default_http_get/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:build, opts}, _from, state) do
    with {:ok, state} <- maybe_stop_for_force(state, opts),
         {:ok, state} <- ensure_idle(state, :build),
         {:ok, state} <- apply_runtime_overrides(state, opts),
         {:ok, state} <- do_build(state) do
      {:reply, {:ok, public_snapshot(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:launch, opts}, _from, state) do
    with {:ok, state} <- maybe_stop_for_force(state, opts),
         {:ok, state} <- ensure_idle(state, :launch),
         {:ok, state} <- apply_runtime_overrides(state, opts),
         {:ok, state} <- do_launch(state) do
      {:reply, {:ok, public_snapshot(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:build_and_launch, opts}, _from, state) do
    with {:ok, state} <- maybe_stop_for_force(state, opts),
         {:ok, state} <- ensure_idle(state, :build_and_launch),
         {:ok, state} <- apply_runtime_overrides(state, opts),
         {:ok, state} <- do_build(state),
         {:ok, state} <- do_launch(state) do
      {:reply, {:ok, public_snapshot(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  def handle_call({:tail_log, lines}, _from, state) do
    case tail_log_file(state.log_path, lines) do
      {:ok, payload} -> {:reply, {:ok, payload}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:inspect_targets, _from, %{status: :running} = state) do
    url = "http://127.0.0.1:#{state.remote_debug_port}/json/list"

    case state.http_get.(url) do
      {:ok, targets} ->
        {:reply,
         {:ok,
          %{
            remote_debug_port: state.remote_debug_port,
            main_inspect_port: state.main_inspect_port,
            main_inspect_url: "devtools://devtools/bundled/js_app.html?experiments=true&v8only=true&ws=127.0.0.1:#{state.main_inspect_port}",
            targets: targets
          }}, state}

      {:error, reason} ->
        {:reply, {:error, {:inspect_failed, reason}}, state}
    end
  end

  def handle_call(:inspect_targets, _from, state) do
    {:reply, {:error, {:invalid_state, state.status, "Electron must be running to inspect targets"}}, state}
  end

  def handle_call(:stop, _from, state) do
    case stop_process(state) do
      {:ok, state} -> {:reply, {:ok, public_snapshot(state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_port(port) do
    append_log(state.log_path, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    last_exit = %{
      status: status,
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Logger.info("Electron session process exited status=#{status}")

    state = %{
      state
      | status: if(status == 0, do: :stopped, else: :crashed),
        port: nil,
        os_pid: nil,
        last_exit: last_exit
    }

    {:noreply, state}
  end

  def handle_info({:startup_timeout, ref}, state) do
    if state.status == :starting and state.port do
      case :erlang.port_info(state.port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
          {:noreply, %{state | status: :running, os_pid: os_pid, started_at: DateTime.utc_now()}}

        _ ->
          if Process.get({:startup_timer, ref}) do
            Process.delete({:startup_timer, ref})
            {:noreply, %{state | status: :running, started_at: DateTime.utc_now()}}
          else
            {:noreply, state}
          end
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp server(opts), do: Keyword.get(opts, :server, @name)

  defp config_snapshot do
    case Config.settings() do
      {:ok, settings} ->
        electron = settings.electron

        %{
          game_folder: resolve_game_folder(electron),
          game_name: resolve_game_name(electron),
          compile_script: electron.compile_script,
          npm_command: electron.npm_command,
          main_inspect_port: electron.main_inspect_port,
          remote_debug_port: electron.remote_debug_port,
          build_timeout_ms: electron.build_timeout_ms,
          startup_timeout_ms: electron.startup_timeout_ms,
          log_dir: electron.log_dir
        }

      {:error, _} ->
        default_electron_config()
    end
  end

  defp default_electron_config do
    %{
      game_folder: resolve_game_folder(%{}),
      game_name: resolve_game_name(%{}),
      compile_script: "scripts/compileGame",
      npm_command: "npm run electron",
      main_inspect_port: @default_main_inspect_port,
      remote_debug_port: @default_remote_debug_port,
      build_timeout_ms: @default_build_timeout_ms,
      startup_timeout_ms: @default_startup_timeout_ms,
      log_dir: "debug"
    }
  end

  defp resolve_game_folder(electron) do
    cond do
      folder = fetch_config(electron, :game_folder) -> expand_path(folder)
      env = System.get_env("GAME_FOLDER") -> expand_path(env)
      true -> nil
    end
  end

  defp resolve_game_name(electron) do
    fetch_config(electron, :game_name) || System.get_env("ELECTRON_GAME_NAME")
  end

  defp fetch_config(%{} = electron, key) do
    Map.get(electron, key) || Map.get(electron, Atom.to_string(key))
  end

  defp fetch_config(_, _), do: nil

  defp expand_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> Path.expand()
  end

  defp apply_runtime_overrides(state, opts) do
    game_folder =
      opts
      |> Keyword.get(:game_folder)
      |> case do
        folder when is_binary(folder) and folder != "" -> expand_path(folder)
        _ -> state.game_folder || config_snapshot().game_folder
      end

    game_name =
      opts
      |> Keyword.get(:game_name)
      |> case do
        name when is_binary(name) and name != "" -> name
        _ -> state.game_name || config_snapshot().game_name
      end

    cond do
      is_nil(game_folder) or not File.dir?(game_folder) ->
        {:error, {:invalid_game_folder, game_folder || "missing GAME_FOLDER or electron.game_folder"}}

      is_nil(game_name) or game_name == "" ->
        {:error, {:missing_game_name, "Set electron.game_name or ELECTRON_GAME_NAME"}}

      true ->
        {:ok,
         %{
           state
           | game_folder: game_folder,
             game_name: game_name,
             main_inspect_port: Keyword.get(opts, :main_inspect_port, state.main_inspect_port),
             remote_debug_port: Keyword.get(opts, :remote_debug_port, state.remote_debug_port)
         }}
    end
  end

  defp maybe_stop_for_force(%{status: status} = state, opts) when status in [:running, :starting] do
    if Keyword.get(opts, :force, false) do
      stop_process(state)
    else
      {:error, {:busy, status, "Pass force: true to stop the running session first"}}
    end
  end

  defp maybe_stop_for_force(state, _opts), do: {:ok, state}

  defp ensure_idle(%{status: status} = state, _action) when status in [:idle, :stopped, :crashed] do
    {:ok, %{state | status: :idle}}
  end

  defp ensure_idle(%{status: status}, _action), do: {:error, {:busy, status}}

  defp do_build(%{status: :idle} = state) do
    state = %{state | status: :building, build_result: nil}
    script_path = Path.join(state.game_folder, state.compile_script)
    command = shell_quote(script_path) <> " " <> shell_quote(state.game_name)

    Logger.info("Electron build starting game=#{state.game_name} folder=#{state.game_folder}")

    {output, exit_status} =
      state.command_runner.(command, state.game_folder,
        timeout: state.build_timeout_ms,
        stderr_to_stdout: true
      )

    build_result = %{
      exit_status: exit_status,
      output: truncate_output(output),
      command: command
    }

    if exit_status == 0 do
      {:ok, %{state | status: :idle, build_result: build_result}}
    else
      {:error, {:build_failed, build_result}}
    end
  end

  defp do_launch(%{status: :idle} = state) do
    log_path = new_log_path(state)
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "Symphony Electron session log\n", [:write])

    launch_command =
      [
        state.npm_command,
        "--",
        "--inspect=#{state.main_inspect_port}",
        "--remote-debugging-port=#{state.remote_debug_port}",
        "--enable-logging=stderr"
      ]
      |> Enum.join(" ")

    Logger.info("Electron launch command=#{launch_command} cwd=#{state.game_folder}")

    state = %{state | status: :starting, log_path: log_path, last_exit: nil}

    case state.port_starter.(launch_command, cd: state.game_folder) do
      {:ok, port} ->
        os_pid =
          case :erlang.port_info(port, :os_pid) do
            {:os_pid, pid} when is_integer(pid) -> pid
            _ -> nil
          end

        ref = schedule_startup_timeout(state.startup_timeout_ms)

        Process.put({:startup_timer, ref}, true)

        {:ok,
         %{
           state
           | port: port,
             os_pid: os_pid,
             status: if(os_pid, do: :running, else: :starting),
             started_at: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, {:launch_failed, reason}}
    end
  end

  defp stop_process(%{port: port} = state) when is_port(port) do
    state = %{state | status: :stopping}

    os_pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    Port.close(port)

    if os_pid do
      _ = kill_os_tree(os_pid)
    end

    Process.sleep(@stop_grace_ms)

    {:ok,
     %{
       state
       | status: :stopped,
         port: nil,
         os_pid: nil
     }}
  end

  defp stop_process(%{status: status} = state) when status in [:idle, :stopped, :crashed] do
    {:ok, state}
  end

  defp stop_process(%{status: :building} = _state) do
    {:error, {:busy, :building, "Wait for build to finish before stopping"}}
  end

  defp stop_process(state), do: {:ok, %{state | status: :stopped}}

  defp schedule_startup_timeout(ms) do
    ref = make_ref()
    Process.send_after(self(), {:startup_timeout, ref}, ms)
    ref
  end

  defp new_log_path(state) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> Integer.to_string()

    Path.join([state.game_folder, state.log_dir, "symphony-electron-#{stamp}.log"])
  end

  defp append_log(nil, _data), do: :ok

  defp append_log(log_path, data) when is_binary(log_path) do
    File.write!(log_path, data, [:append])
  end

  defp tail_log_file(nil, _lines), do: {:error, :no_log_file}

  defp tail_log_file(log_path, lines) do
    if File.exists?(log_path) do
      content = File.read!(log_path)
      tail = content |> String.split("\n", trim: false) |> Enum.take(-lines) |> Enum.join("\n")
      {:ok, %{log_path: log_path, lines: lines, content: tail}}
    else
      {:error, {:log_not_found, log_path}}
    end
  end

  defp public_snapshot(state) do
    %{
      status: state.status,
      game_folder: state.game_folder,
      game_name: state.game_name,
      main_inspect_port: state.main_inspect_port,
      remote_debug_port: state.remote_debug_port,
      main_inspect_url:
        if(state.status == :running,
          do: "chrome-devtools://devtools/bundled/inspector.html?ws=127.0.0.1:#{state.main_inspect_port}",
          else: nil
        ),
      remote_debug_url:
        if(state.status == :running,
          do: "http://127.0.0.1:#{state.remote_debug_port}",
          else: nil
        ),
      log_path: state.log_path,
      os_pid: state.os_pid,
      build_result: state.build_result,
      started_at: state.started_at && DateTime.to_iso8601(state.started_at),
      last_exit: state.last_exit
    }
  end

  defp truncate_output(output) when is_binary(output) do
    if String.length(output) > 20_000 do
      String.slice(output, -20_000, 20_000)
    else
      output
    end
  end

  defp shell_quote(value) when is_binary(value) do
    if String.match?(value, ~r/[\s"]/) do
      "\"" <> String.replace(value, "\"", "\\\"") <> "\""
    else
      value
    end
  end

  defp default_command_runner(command, cwd, opts) do
    timeout = Keyword.get(opts, :timeout, @default_build_timeout_ms)

    task =
      Task.async(fn ->
        shell_command(command, cwd, Keyword.take(opts, [:stderr_to_stdout]))
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"", 124}
    end
  end

  defp shell_command(command, cwd, opts) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("cmd.exe", ["/c", command], Keyword.put(opts, :cd, cwd))

      _ ->
        System.cmd("sh", ["-lc", command], Keyword.put(opts, :cd, cwd))
    end
  end

  defp default_port_starter(command, opts) do
    cwd = Keyword.fetch!(opts, :cd)
    spawn_command = shell_spawn_command(command, cwd)

    port =
      Port.open(
        {:spawn, spawn_command},
        [:binary, :exit_status, :stderr_to_stdout, {:line, 65_536}]
      )

    {:ok, port}
  end

  defp shell_spawn_command(command, cwd) do
    escaped_cwd = String.replace(cwd, "\"", "\\\"")

    case :os.type() do
      {:win32, _} ->
        "cmd.exe /c cd /d \"#{escaped_cwd}\" && #{command}"

      _ ->
        "sh -lc 'cd #{shell_quote(cwd)} && #{command}'"
    end
  end

  defp default_http_get(url) do
    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kill_os_tree(os_pid) when is_integer(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  end
end
