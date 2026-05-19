defmodule SymphonyElixirWeb.Components.TaskBadges do
  @moduledoc """
  Shared badges for local-only tasks and overnight task groups.
  """

  use Phoenix.Component

  attr :class, :string, default: nil

  def local_only_badge(assigns) do
    ~H"""
    <span class={["state-badge state-badge-local", @class]} title="Runs via local Ollama only">
      local only
    </span>
    """
  end

  attr :id, :integer, required: true
  attr :class, :string, default: nil
  attr :link, :boolean, default: true

  def task_group_badge(assigns) do
    ~H"""
    <span :if={!@link} class={["state-badge state-badge-group", @class]} title={"Overnight task group ##{@id}"}>
      group #<%= @id %>
    </span>
    <a
      :if={@link}
      href={"/task-groups/#{@id}"}
      class={["state-badge state-badge-group task-group-badge-link", @class]}
      title={"Overnight task group ##{@id}"}
    >
      group #<%= @id %>
    </a>
    """
  end

  attr :task, :map, required: true
  attr :class, :string, default: "task-badges"

  def task_badges(assigns) do
    ~H"""
    <span :if={@task.local_only or @task.task_group_id} class={@class}>
      <.local_only_badge :if={@task.local_only} />
      <.task_group_badge :if={@task.task_group_id} id={@task.task_group_id} />
    </span>
    """
  end
end
