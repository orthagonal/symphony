defmodule SymphonyElixir.TaskQueue do
  @moduledoc """
  Processes queued tasks one at a time (FIFO), grouping same-repo tasks for shared git branches.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Cursor.Dispatch
  alias SymphonyElixir.LocalDispatch
  alias SymphonyElixir.Tasks
  alias SymphonyElixir.Tasks.Task

  @pubsub SymphonyElixir.PubSub
  @topic "task_queue"
  @poll_ms 2_000
  @terminal ~w(done failed cancelled)

  def start_link(opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      %{status: :idle, queue: [], waiting_task_id: nil},
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @spec status() :: map()
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      %{status: :idle, waiting_task_id: nil, remaining: 0}
    end
  end

  @spec go() :: :ok
  def go do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :go), else: :ok
  end

  @spec stop_processing() :: :ok
  def stop_processing do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :stop), else: :ok
  end

  @spec notify_task_terminal(integer()) :: :ok
  def notify_task_terminal(task_id) when is_integer(task_id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:task_terminal, task_id})
    end

    :ok
  end

  @doc """
  Synchronously drops a task id from any in-memory queue snapshot and advances execution
  if that task was the active `waiting_task_id`.

  Called before deleting a row from persistence so `:poll` does not crash on missing tasks.
  """
  @spec ack_task_removed(integer()) :: :ok
  def ack_task_removed(task_id) when is_integer(task_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        _ = GenServer.call(pid, {:ack_task_removed, task_id})

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  def handle_call({:ack_task_removed, task_id}, _from, state) when is_integer(task_id) do
    state = %{state | queue: Enum.reject(state.queue, fn {t, _} -> t.id == task_id end)}

    state =
      if state.waiting_task_id == task_id do
        advance(%{state | waiting_task_id: nil})
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:go, %{status: :running} = state) do
    {:noreply, state}
  end

  def handle_cast(:go, state) do
    queued = Tasks.list_queued()

    if queued == [] do
      broadcast(:idle, %{message: "No queued tasks"})
      {:noreply, state}
    else
      queue = build_queue(queued)
      Logger.info("TaskQueue starting #{length(queue)} task(s) in #{batch_count(queue)} batch(es)")

      state =
        %{state | status: :running, queue: queue, waiting_task_id: nil}
        |> start_next()

      {:noreply, state}
    end
  end

  def handle_cast(:stop, state) do
    {:noreply, %{state | status: :idle, queue: [], waiting_task_id: nil}}
  end

  def handle_cast({:task_terminal, task_id}, %{waiting_task_id: task_id} = state) do
    {:noreply, advance(state)}
  end

  def handle_cast({:task_terminal, _task_id}, state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, %{waiting_task_id: task_id} = state) when is_integer(task_id) do
    task = Tasks.get!(task_id)

    cond do
      task.status in @terminal ->
        {:noreply, advance(state)}

      agent_failed?(task_id) and task.status == "running" ->
        Tasks.update_status!(task_id, "review")

        _ =
          Tasks.log_event!(
            task_id,
            "status",
            "Marked review after cursor-agent failure — resolve on Reviews screen"
          )

        {:noreply, state}

      true ->
        schedule_poll()
        {:noreply, state}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  defp start_next(%{queue: []} = state) do
    broadcast(:idle, %{message: "Queue finished"})
    %{state | status: :idle, waiting_task_id: nil}
  end

  defp start_next(%{queue: [{task, batch} | rest]} = state) do
    Tasks.update!(task.id, %{
      queue_batch_id: batch.id,
      queue_batch_index: batch.index,
      queue_batch_total: batch.total,
      status: "running"
    })

    Tasks.log_event!(task.id, "queue", batch_log_message(batch))

    :ok =
      if task.local_only do
        LocalDispatch.start_async(task.id, git_batch: batch)
      else
        Dispatch.start_async(task.id,
          auto_plan: true,
          open_ide: false,
          run_agent: true,
          git_batch: batch
        )
      end

    schedule_poll()

    %{
      state
      | queue: rest,
        waiting_task_id: task.id
    }
    |> tap(fn _ -> broadcast(:running, %{task_id: task.id, batch: batch}) end)
  end

  defp advance(state) do
    start_next(%{state | waiting_task_id: nil})
  end

  defp build_queue(tasks) do
    tasks
    |> Enum.chunk_by(&project_key/1)
    |> Enum.flat_map(&batch_entries/1)
  end

  defp batch_entries(tasks) do
    batch_id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    total = length(tasks)
    branch = batch_branch_name(hd(tasks))

    Enum.with_index(tasks, 1)
    |> Enum.map(fn {task, index} ->
      role =
        cond do
          total == 1 -> :solo
          index == 1 -> :first
          index == total -> :last
          true -> :middle
        end

      batch = %{
        id: batch_id,
        index: index,
        total: total,
        role: role,
        branch: branch,
        project_key: project_key(task)
      }

      {task, batch}
    end)
  end

  defp batch_branch_name(%Task{} = task) do
    slug =
      task.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 32)

    slug = if slug == "", do: "work", else: slug
    "symphony/#{slug}-#{:os.system_time(:second)}"
  end

  defp project_key(%Task{project_path: path}) when is_binary(path) and path != "" do
    path |> Path.expand() |> String.downcase()
  end

  defp project_key(_), do: "default"

  defp batch_count(queue) do
    queue
    |> Enum.map(fn {_task, batch} -> batch.id end)
    |> Enum.uniq()
    |> length()
  end

  defp batch_log_message(batch) do
    "Queue batch #{batch.id} (#{batch.index}/#{batch.total}, role=#{batch.role}, branch=#{batch.branch})"
  end

  defp agent_failed?(task_id) do
    Tasks.list_events(task_id)
    |> Enum.any?(fn e -> e.kind == "agent_failed" end)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_ms)
  end

  defp public_status(state) do
    %{
      status: state.status,
      waiting_task_id: state.waiting_task_id,
      remaining: length(state.queue)
    }
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {event, payload})
  end
end
