defmodule SymphonyElixir.Codex.DispatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Dispatch

  test "run_codex_agent runs AppServer inline (no nested Task.Supervisor child)" do
    source = File.read!(Path.join(["lib", "symphony_elixir", "codex", "dispatch.ex"]))

    refute source =~ ~r/run_codex_agent[\s\S]*?Task\.Supervisor\.start_child/
  end

  test "run_codex_agent logs before AppServer.run and handles result" do
    source = File.read!(Path.join(["lib", "symphony_elixir", "codex", "dispatch.ex"]))

    assert source =~ "Calling AppServer.run/3"
    assert source =~ "AppServer.run(workspace, prompt, issue)"
    assert source =~ ~s/agent_done/, "Codex turn finished successfully"
    assert source =~ ~s/agent_failed/
  end

  test "start_async spawns a single background task that runs AppServer inline" do
    source = File.read!(Path.join(["lib", "symphony_elixir", "codex", "dispatch.ex"]))

    assert [_, _] = Regex.scan(~r/Task\.Supervisor\.start_child/, source)
    assert source =~ "def start_async"
    assert source =~ "defp run_codex_agent"
  end
end
