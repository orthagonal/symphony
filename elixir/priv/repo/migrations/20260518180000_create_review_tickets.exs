defmodule SymphonyElixir.Repo.Migrations.CreateReviewTickets do
  use Ecto.Migration

  def change do
    create table(:review_tickets) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :status, :string, null: false, default: "open"
      add :summary, :text
      add :checklist, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_tickets, [:status])
    create unique_index(:review_tickets, [:task_id])

    alter table(:tasks) do
      add :queue_batch_id, :string
      add :queue_batch_index, :integer
      add :queue_batch_total, :integer
    end
  end
end
