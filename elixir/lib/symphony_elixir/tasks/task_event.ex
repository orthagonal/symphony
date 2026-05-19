defmodule SymphonyElixir.Tasks.TaskEvent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "task_events" do
    belongs_to :task, SymphonyElixir.Tasks.Task

    field :kind, :string
    field :message, :string
    field :metadata, :map

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :kind, :message, :metadata])
    |> validate_required([:task_id, :kind])
  end
end
