defmodule SymphonyElixir.Reviews.ReviewTicket do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Tasks.Task

  @statuses ~w(open done)

  schema "review_tickets" do
    field :title, :string
    field :status, :string, default: "open"
    field :summary, :string
    field :checklist, {:array, :map}, default: []

    belongs_to :task, Task

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:task_id, :title, :status, :summary, :checklist])
    |> validate_required([:task_id, :title, :status, :checklist])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
