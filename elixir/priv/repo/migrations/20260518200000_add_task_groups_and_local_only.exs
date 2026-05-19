defmodule SymphonyElixir.Repo.Migrations.AddTaskGroupsAndLocalOnly do
  use Ecto.Migration

  def change do
    create table(:task_groups) do
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:task_groups, [:status])

    alter table(:tasks) do
      add :task_group_id, references(:task_groups, on_delete: :nilify_all)
      add :local_only, :boolean, null: false, default: false
    end

    create index(:tasks, [:task_group_id])
    create index(:tasks, [:local_only])
  end
end
