defmodule SymphonyElixir.Repo.Migrations.AddChecklistToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :checklist, {:array, :map}, default: []
    end
  end
end
