defmodule SymphonyElixir.Agent do
  @moduledoc """
  Facade for shared agent memory managed by `SymphonyElixir.Agent.Memory`.
  """

  alias SymphonyElixir.Agent.Memory

  @spec write(Memory.task_group_id(), Memory.task_id(), Memory.key(), term()) :: :ok | {:error, term()}
  def write(task_group_id, task_id, key, value),
    do: Memory.write(task_group_id, task_id, key, value)

  @spec read(Memory.task_group_id(), keyword()) :: {:ok, [Memory.entry()]} | {:error, term()}
  def read(task_group_id, opts \\ []), do: Memory.read(task_group_id, opts)

  @spec fetch(Memory.task_group_id(), Memory.key()) :: {:ok, Memory.entry()} | {:error, term()}
  def fetch(task_group_id, key), do: Memory.fetch(task_group_id, key)

  @spec delete(Memory.task_group_id(), Memory.key()) :: :ok | {:error, term()}
  def delete(task_group_id, key), do: Memory.delete(task_group_id, key)

  @spec clear(Memory.task_group_id()) :: :ok | {:error, term()}
  def clear(task_group_id), do: Memory.clear(task_group_id)

  @spec status() :: map()
  def status, do: Memory.status()
end
