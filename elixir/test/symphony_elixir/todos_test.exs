defmodule SymphonyElixir.TodosTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Todos
  alias SymphonyElixir.Todos.TodoItem

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-todos-#{System.unique_integer([:positive])}.db"
      )

    File.rm(db_path)
    Application.put_env(:symphony_elixir, :tasks_database_path, db_path)
    SymphonyElixir.Tasks.configure_repo!()
    start_supervised!(SymphonyElixir.Repo)
    Ecto.Migrator.run(SymphonyElixir.Repo, :up, all: true)

    on_exit(fn -> File.rm(db_path) end)

    :ok
  end

  test "create, link, and delete todos" do
    assert {:ok, todo} =
             Todos.create(%{
               "title" => "Ship feature",
               "notes" => "Remember tests",
               "status" => "queued"
             })

    assert todo.title == "Ship feature"
    assert todo.status == "queued"
    assert %DateTime{} = todo.inserted_at

    assert {:ok, todo} = Todos.append_link(todo, "https://example.com/a")
    assert {:ok, todo} = Todos.append_link(todo, "https://example.com/a")
    assert todo.links == ["https://example.com/a"]

    assert {:ok, todo} = Todos.remove_link_at(todo, 0)
    assert todo.links == []

    assert {:ok, todo} = Todos.append_checklist_item(todo, "Write tests")
    assert {:ok, todo} = Todos.append_checklist_item(todo, "Ship it")
    assert length(todo.checklist) == 2
    assert hd(todo.checklist)["text"] == "Write tests"
    refute hd(todo.checklist)["done"]

    assert {:ok, todo} = Todos.toggle_checklist_item(todo, 0)
    assert hd(todo.checklist)["done"]

    assert {:ok, todo} = Todos.remove_checklist_item_at(todo, 1)
    assert length(todo.checklist) == 1

    assert {:ok, updated} = Todos.update(todo, %{"status" => "finished"})
    assert updated.status == "finished"

    assert [listed] = Todos.list_all()
    assert listed.id == todo.id

    assert %TodoItem{} = Todos.delete!(todo.id)
    assert Todos.list_all() == []
  end

  test "rejects invalid status" do
    assert {:error, changeset} = Todos.create(%{"title" => "x", "status" => "invalid"})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :status)
  end
end
