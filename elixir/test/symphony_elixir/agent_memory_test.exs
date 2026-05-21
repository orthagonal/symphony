defmodule SymphonyElixir.Agent.MemoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent
  alias SymphonyElixir.Agent.Memory

  setup do
    name = :"agent_memory_#{System.unique_integer()}"

    pid =
      start_supervised!(
        {Memory, name: name}
      )

    %{memory: name, pid: pid}
  end

  test "write and read entries within a task group", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "summary", "built genserver", memory)

    assert {:ok, [entry]} = Memory.read(10, [], memory)
    assert entry.key == "summary"
    assert entry.value == "built genserver"
    assert entry.task_id == 50
    assert %DateTime{} = entry.updated_at
  end

  test "tasks in the same group share one memory space", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "step", "first", memory)
    assert :ok = Memory.write(10, 51, "step", "second", memory)

    assert {:ok, entries} = Memory.read(10, [], memory)
    assert length(entries) == 1
    assert hd(entries).value == "second"
    assert hd(entries).task_id == 51
  end

  test "read filters by task id", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "a", 1, memory)
    assert :ok = Memory.write(10, 50, "b", 2, memory)
    assert :ok = Memory.write(10, 51, "c", 3, memory)

    assert {:ok, entries} = Memory.read(10, [task_id: 50], memory)
    assert Enum.map(entries, & &1.key) == ["a", "b"]
  end

  test "fetch returns a single entry", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "notes", %{done: true}, memory)
    assert {:ok, entry} = Memory.fetch(10, "notes", memory)
    assert entry.value == %{done: true}
  end

  test "delete and clear manage group memory", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "temp", "value", memory)
    assert :ok = Memory.delete(10, "temp", memory)
    assert {:error, :not_found} = Memory.fetch(10, "temp", memory)

    assert :ok = Memory.write(10, 50, "keep", "until clear", memory)
    assert :ok = Memory.clear(10, memory)
    assert {:ok, []} = Memory.read(10, [], memory)
  end

  test "status summarizes stored groups", %{memory: memory} do
    assert :ok = Memory.write(10, 50, "a", 1, memory)
    assert :ok = Memory.write(11, 60, "b", 2, memory)

    assert %{group_count: 2, groups: %{10 => 1, 11 => 1}} = Memory.status(memory)
  end

  test "validates ids and keys", %{memory: memory} do
    assert {:error, :invalid_task_group_id} = Memory.write(0, 50, "k", "v", memory)
    assert {:error, :invalid_task_id} = Memory.write(10, 0, "k", "v", memory)
    assert {:error, :invalid_key} = Memory.write(10, 50, "", "v", memory)
  end

  test "facade module delegates to Memory" do
    assert function_exported?(Agent, :write, 4)
    assert function_exported?(Agent, :read, 2)
    assert function_exported?(Agent, :status, 0)
  end
end
