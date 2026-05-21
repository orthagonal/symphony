defmodule SymphonyElixir.Agent.Memory do
  @moduledoc """
  GenServer that stores one shared memory space per task group.

  Tasks in the same group read and write entries keyed by name, tagged with the
  writing task's id. Later tasks in a batch can inspect what earlier tasks stored.
  """

  use GenServer

  @name __MODULE__

  @type task_group_id :: pos_integer()
  @type task_id :: pos_integer()
  @type key :: String.t()
  @type entry :: %{
          required(:key) => key(),
          required(:value) => term(),
          required(:task_id) => task_id(),
          required(:updated_at) => DateTime.t()
        }

  @type state :: %{
          groups: %{task_group_id() => %{key() => entry()}}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @spec write(task_group_id(), task_id(), key(), term(), GenServer.server()) :: :ok | {:error, term()}
  def write(task_group_id, task_id, key, value, server \\ @name) do
    GenServer.call(server, {:write, task_group_id, task_id, key, value})
  end

  @spec read(task_group_id(), keyword(), GenServer.server()) :: {:ok, [entry()]} | {:error, term()}
  def read(task_group_id, opts \\ [], server \\ @name) do
    GenServer.call(server, {:read, task_group_id, opts})
  end

  @spec fetch(task_group_id(), key(), GenServer.server()) :: {:ok, entry()} | {:error, term()}
  def fetch(task_group_id, key, server \\ @name) do
    GenServer.call(server, {:fetch, task_group_id, key})
  end

  @spec delete(task_group_id(), key(), GenServer.server()) :: :ok | {:error, term()}
  def delete(task_group_id, key, server \\ @name) do
    GenServer.call(server, {:delete, task_group_id, key})
  end

  @spec clear(task_group_id(), GenServer.server()) :: :ok | {:error, term()}
  def clear(task_group_id, server \\ @name) do
    GenServer.call(server, {:clear, task_group_id})
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ @name), do: GenServer.call(server, :status)

  @impl true
  def init(_opts), do: {:ok, %{groups: %{}}}

  @impl true
  def handle_call({:write, task_group_id, task_id, key, value}, _from, state) do
    with :ok <- validate_group_id(task_group_id),
         :ok <- validate_task_id(task_id),
         :ok <- validate_key(key) do
      entry = %{
        key: key,
        value: value,
        task_id: task_id,
        updated_at: DateTime.utc_now()
      }

      group = Map.get(state.groups, task_group_id, %{})
      groups = Map.put(state.groups, task_group_id, Map.put(group, key, entry))
      {:reply, :ok, %{state | groups: groups}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, task_group_id, opts}, _from, state) do
    with :ok <- validate_group_id(task_group_id) do
      entries =
        state.groups
        |> Map.get(task_group_id, %{})
        |> Map.values()
        |> filter_entries(opts)
        |> Enum.sort_by(& &1.updated_at, DateTime)

      {:reply, {:ok, entries}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, task_group_id, key}, _from, state) do
    with :ok <- validate_group_id(task_group_id),
         :ok <- validate_key(key) do
      case get_in(state.groups, [task_group_id, key]) do
        entry when is_map(entry) -> {:reply, {:ok, entry}, state}
        _ -> {:reply, {:error, :not_found}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, task_group_id, key}, _from, state) do
    with :ok <- validate_group_id(task_group_id),
         :ok <- validate_key(key) do
      groups = update_in(state.groups, [task_group_id], fn
        nil -> nil
        group -> Map.delete(group, key)
      end)

      groups =
        case Map.get(groups, task_group_id) do
          map when map == %{} -> Map.delete(groups, task_group_id)
          _ -> groups
        end

      {:reply, :ok, %{state | groups: groups}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:clear, task_group_id}, _from, state) do
    with :ok <- validate_group_id(task_group_id) do
      {:reply, :ok, %{state | groups: Map.delete(state.groups, task_group_id)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    summary =
      state.groups
      |> Enum.map(fn {group_id, entries} ->
        {group_id, map_size(entries)}
      end)
      |> Map.new()

    {:reply, %{group_count: map_size(state.groups), groups: summary}, state}
  end

  defp filter_entries(entries, opts) do
    entries
    |> maybe_filter_task_id(Keyword.get(opts, :task_id))
    |> maybe_filter_key(Keyword.get(opts, :key))
  end

  defp maybe_filter_task_id(entries, nil), do: entries
  defp maybe_filter_task_id(entries, task_id), do: Enum.filter(entries, &(&1.task_id == task_id))

  defp maybe_filter_key(entries, nil), do: entries
  defp maybe_filter_key(entries, key), do: Enum.filter(entries, &(&1.key == key))

  defp validate_group_id(id) when is_integer(id) and id > 0, do: :ok
  defp validate_group_id(_), do: {:error, :invalid_task_group_id}

  defp validate_task_id(id) when is_integer(id) and id > 0, do: :ok
  defp validate_task_id(_), do: {:error, :invalid_task_id}

  defp validate_key(key) when is_binary(key) and key != "", do: :ok
  defp validate_key(_), do: {:error, :invalid_key}
end
