defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    :ok = SymphonyElixir.Tasks.configure_repo!()

    children =
      database_children() ++
        queue_children() ++
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.Agent.Memory,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp database_children do
    if local_tracker?() do
      [SymphonyElixir.Repo, SymphonyElixir.DatabaseSetup]
    else
      []
    end
  end

  defp local_tracker? do
    case SymphonyElixir.Workflow.load() do
      {:ok, %{config: %{"tracker" => %{"kind" => "local"}}}} -> true
      _ -> false
    end
  end

  defp queue_children do
    if local_tracker?(), do: [SymphonyElixir.TaskQueue], else: []
  end
end
