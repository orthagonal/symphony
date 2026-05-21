defmodule SymphonyElixir.Electron.SessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Electron.Session

  setup do
    folder =
      Path.join(System.tmp_dir!(), "symphony-electron-#{System.unique_integer()}")
      |> tap(&File.mkdir_p!/1)

    script_dir = Path.join(folder, "scripts")
    File.mkdir_p!(script_dir)
    File.write!(Path.join(script_dir, "compileGame"), ":\n")

    name = :"electron_session_#{System.unique_integer()}"

    pid =
      start_supervised!(
        {Session,
         [
           name: name,
           command_runner: fn _command, _cwd, _opts -> {"build ok", 0} end,
           port_starter: &long_running_port/2,
           http_get: fn _url -> {:ok, [%{"type" => "page", "title" => "Game"}]} end
         ]}
      )

    %{session: name, pid: pid, folder: folder}
  end

  test "build stores result and returns to idle", %{session: session, folder: folder} do
    assert {:ok, snapshot} =
             Session.build(server: session, game_folder: folder, game_name: "demo")

    assert snapshot.status == :idle
    assert snapshot.build_result.exit_status == 0
  end

  test "build_and_launch starts a running session", %{session: session, folder: folder} do
    assert {:ok, snapshot} =
             Session.build_and_launch(server: session, game_folder: folder, game_name: "demo")

    assert snapshot.status in [:running, :starting]
    assert snapshot.log_path =~ "symphony-electron"
  end

  test "inspect_targets reads CDP list when running", %{session: session, folder: folder} do
    assert {:ok, _} =
             Session.build_and_launch(server: session, game_folder: folder, game_name: "demo")

    assert {:ok, payload} = Session.inspect_targets(session)
    assert payload.remote_debug_port == 9222
    assert is_list(payload.targets)
  end

  test "tail_log returns recent log lines", %{session: session, folder: folder} do
    assert {:ok, _} =
             Session.build_and_launch(server: session, game_folder: folder, game_name: "demo")

    assert {:ok, payload} = Session.tail_log(10, session)
    assert payload.content =~ "Symphony Electron session log"
  end

  test "stop clears running session", %{session: session, folder: folder} do
    assert {:ok, _} =
             Session.build_and_launch(server: session, game_folder: folder, game_name: "demo")

    assert {:ok, snapshot} = Session.stop(session)
    assert snapshot.status == :stopped
  end

  defp long_running_port(_command, opts) do
    cwd = Keyword.fetch!(opts, :cd)
    escaped_cwd = String.replace(cwd, "\"", "\\\"")

    spawn_command =
      case :os.type() do
        {:win32, _} -> "cmd.exe /c cd /d \"#{escaped_cwd}\" && ping -n 30 127.0.0.1"
        _ -> "sh -lc 'cd #{cwd} && sleep 30'"
      end

    port =
      Port.open(
        {:spawn, spawn_command},
        [:binary, :exit_status, :stderr_to_stdout, {:line, 65_536}]
      )

    {:ok, port}
  end
end

defmodule SymphonyElixir.Electron.ToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Electron.Tool

  test "tool_spec advertises electron_debug actions" do
    assert %{
             "name" => "electron_debug",
             "inputSchema" => %{
               "properties" => %{"action" => %{"enum" => actions}},
               "required" => ["action"]
             }
           } = Tool.tool_spec()

    assert "build_and_launch" in actions
    assert "stop" in actions
  end

  test "dynamic tool specs include electron_debug" do
    names = DynamicTool.tool_specs() |> Enum.map(& &1["name"])
    assert "electron_debug" in names
    assert "linear_graphql" in names
  end

  test "execute rejects invalid actions" do
    response = Tool.dynamic_tool_response(Tool.execute(%{"action" => "fly"}))

    assert response["success"] == false
    assert response["output"] =~ "action"
  end
end
