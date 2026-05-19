defmodule SymphonyElixir.AgentRuns.AgentRun do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "agent_runs" do
    belongs_to :task, SymphonyElixir.Tasks.Task

    field :agent_name, :string
    field :status, :string, default: "running"
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :result, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [:task_id, :agent_name, :status, :started_at, :finished_at, :result])
    |> validate_required([:task_id, :status])
  end
end
