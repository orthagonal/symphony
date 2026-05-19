defmodule SymphonyElixir.Repo.Migrations.CreateLocalTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :body, :text
      add :status, :string, null: false, default: "queued"
      add :priority, :integer
      add :assigned_agent, :string
      add :workspace_path, :string
      add :result, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:status])
    create index(:tasks, [:inserted_at])

    create table(:task_events) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :message, :text
      add :metadata, :map

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:task_events, [:task_id])

    create table(:agent_runs) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :agent_name, :string
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :result, :text

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:agent_runs, [:task_id])
  end
end
