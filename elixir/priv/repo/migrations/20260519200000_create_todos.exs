defmodule SymphonyElixir.Repo.Migrations.CreateTodos do
  use Ecto.Migration

  def change do
    create table(:todos) do
      add :title, :string, null: false
      add :notes, :text
      add :status, :string, null: false, default: "queued"
      add :due_at, :utc_datetime_usec
      add :links, {:array, :string}, default: []
      add :task_group_id, references(:task_groups, on_delete: :nilify_all)
      add :task_id, references(:tasks, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:todos, [:status])
    create index(:todos, [:task_group_id])
    create index(:todos, [:task_id])
    create index(:todos, [:inserted_at])
  end
end
