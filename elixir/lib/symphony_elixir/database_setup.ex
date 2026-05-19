defmodule SymphonyElixir.DatabaseSetup do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Tasks

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Tasks.migrate_up!()
    {:ok, %{}}
  end
end
