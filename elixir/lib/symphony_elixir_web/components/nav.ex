defmodule SymphonyElixirWeb.Components.Nav do
  @moduledoc false

  use Phoenix.Component

  attr(:current, :atom, required: true)

  @spec agent_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_nav(assigns) do
    ~H"""
    <nav class="agent-nav" aria-label="Agent manager">
      <a class={nav_class(@current, :dashboard)} href="/">Tasks</a>
      <a class={nav_class(@current, :reviews)} href="/reviews">Reviews</a>
      <a class={nav_class(@current, :new_task)} href="/tasks/new">New</a>
      <a class={nav_class(@current, :task_groups)} href="/task-groups">Groups</a>
      <a class={nav_class(@current, :todos)} href="/todos">Todos</a>
      <a class={nav_class(@current, :agents)} href="/agents">Agents</a>
      <a class={nav_class(@current, :settings)} href="/settings">Settings</a>
      <a class={nav_class(@current, :cursor)} href="/cursor">Cursor</a>
    </nav>
    """
  end

  defp nav_class(current, page) do
    base = "agent-nav-link"

    if current == page do
      "#{base} agent-nav-link-active"
    else
      base
    end
  end
end
