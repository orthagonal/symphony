defmodule SymphonyElixir.Todos do
  @moduledoc """
  Personal todo items with optional links to Symphony tasks and task groups.
  """

  alias SymphonyElixir.Repo
  import Ecto.Query, only: [from: 2]
  alias SymphonyElixir.Todos.TodoItem

  @spec list_all() :: [TodoItem.t()]
  def list_all do
    from(t in TodoItem,
      order_by: [asc: t.status, desc: t.inserted_at],
      preload: [:task_group, :task]
    )
    |> Repo.all()
  end

  @spec get!(integer()) :: TodoItem.t()
  def get!(id) when is_integer(id) do
    TodoItem
    |> Repo.get!(id)
    |> Repo.preload([:task_group, :task])
  end

  @spec create(map()) :: {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %TodoItem{}
    |> TodoItem.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(TodoItem.t(), map()) :: {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def update(%TodoItem{} = todo, attrs) when is_map(attrs) do
    todo
    |> TodoItem.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(TodoItem.t()) :: {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TodoItem{} = todo), do: Repo.delete(todo)

  @spec delete!(integer()) :: TodoItem.t()
  def delete!(id) when is_integer(id) do
    id |> get!() |> Repo.delete!()
  end

  @spec append_link(TodoItem.t(), String.t()) :: {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def append_link(%TodoItem{} = todo, url) when is_binary(url) do
    url = String.trim(url)

    if url == "" do
      {:ok, todo}
    else
      links =
        (todo.links || [])
        |> Kernel.++([url])
        |> Enum.uniq()

      update(todo, %{links: links})
    end
  end

  @spec remove_link_at(TodoItem.t(), non_neg_integer()) ::
          {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def remove_link_at(%TodoItem{} = todo, index) when is_integer(index) and index >= 0 do
    links = todo.links || []

    if index < length(links) do
      {_, rest} = List.pop_at(links, index)
      update(todo, %{links: rest})
    else
      {:ok, todo}
    end
  end

  @spec append_checklist_item(TodoItem.t(), String.t()) ::
          {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def append_checklist_item(%TodoItem{} = todo, text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      {:ok, todo}
    else
      checklist = (todo.checklist || []) ++ [%{"text" => text, "done" => false}]
      update(todo, %{checklist: checklist})
    end
  end

  @spec toggle_checklist_item(TodoItem.t(), non_neg_integer()) ::
          {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def toggle_checklist_item(%TodoItem{} = todo, index) when is_integer(index) and index >= 0 do
    checklist = todo.checklist || []

    if index < length(checklist) do
      updated =
        Enum.with_index(checklist)
        |> Enum.map(fn {item, i} ->
          if i == index do
            done = item["done"] in [true, "true", 1, "1"]
            Map.put(item, "done", !done)
          else
            item
          end
        end)

      update(todo, %{checklist: updated})
    else
      {:ok, todo}
    end
  end

  @spec remove_checklist_item_at(TodoItem.t(), non_neg_integer()) ::
          {:ok, TodoItem.t()} | {:error, Ecto.Changeset.t()}
  def remove_checklist_item_at(%TodoItem{} = todo, index) when is_integer(index) and index >= 0 do
    checklist = todo.checklist || []

    if index < length(checklist) do
      {_, rest} = List.pop_at(checklist, index)
      update(todo, %{checklist: rest})
    else
      {:ok, todo}
    end
  end
end
