defmodule SymphonyElixir.Repo.Migrations.AddTaskProjectPath do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :project_path, :string
      add :workspace_mode, :string, null: false, default: "isolated"
      add :git_metadata, :map
    end

    create index(:tasks, [:project_path])
  end
end
