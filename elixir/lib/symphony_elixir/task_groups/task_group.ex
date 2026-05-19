defmodule SymphonyElixir.TaskGroups.TaskGroup do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active completed cancelled)

  schema "task_groups" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"

    has_many :tasks, SymphonyElixir.Tasks.Task

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:title, :description, :status])
    |> validate_required([:title, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
