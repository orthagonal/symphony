defmodule SymphonyElixir.AgentDispatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.AgentDispatch
  alias SymphonyElixir.Tasks.Task

  describe "resolve/1" do
    test "local_only always uses ollama" do
      task = %Task{local_only: true, assigned_agent: "cursor"}
      assert AgentBackend.resolve(task) == "ollama"
      assert AgentDispatch.resolve(task) == "ollama"
    end

    test "assigned_agent selects backend" do
      for backend <- AgentBackend.backends() do
        task = %Task{local_only: false, assigned_agent: backend}
        assert AgentDispatch.resolve(task) == backend
      end
    end

    test "unknown assigned_agent falls back to cursor" do
      task = %Task{local_only: false, assigned_agent: "claude"}
      assert AgentDispatch.resolve(task) == "cursor"
    end

    test "nil assigned_agent defaults to cursor" do
      task = %Task{local_only: false, assigned_agent: nil}
      assert AgentDispatch.resolve(task) == "cursor"
    end
  end

  describe "backends/0" do
    test "includes all four agents" do
      assert AgentBackend.backends() == ~w(cursor ollama codex zed)
    end
  end
end
