defmodule SymphonyElixir.Tasks.Task do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(queued assigned running waiting blocked review done failed cancelled)
  @workspace_modes ~w(isolated linked)

  schema "tasks" do
    field :title, :string
    field :body, :string
    field :status, :string, default: "queued"
    field :priority, :integer
    field :assigned_agent, :string
    field :project_path, :string
    field :workspace_mode, :string, default: "isolated"
    field :git_metadata, :map
    field :workspace_path, :string
    field :result, :string
    field :queue_batch_id, :string
    field :queue_batch_index, :integer
    field :queue_batch_total, :integer

    has_many :events, SymphonyElixir.Tasks.TaskEvent
    has_one :review_ticket, SymphonyElixir.Reviews.ReviewTicket
    has_many :agent_runs, SymphonyElixir.AgentRuns.AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :body,
      :status,
      :priority,
      :assigned_agent,
      :project_path,
      :workspace_mode,
      :git_metadata,
      :workspace_path,
      :result,
      :queue_batch_id,
      :queue_batch_index,
      :queue_batch_total
    ])
    |> validate_required([:title, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:workspace_mode, @workspace_modes)
    |> validate_optional_priority()
    |> validate_project_path()
    |> normalize_project_path()
    |> refresh_git_metadata()
  end

  defp validate_project_path(changeset) do
    validate_change(changeset, :project_path, fn :project_path, path ->
      cond do
        is_nil(path) or path == "" -> []
        File.dir?(path) -> []
        true -> [project_path: "must be an existing directory"]
      end
    end)
  end

  defp normalize_project_path(changeset) do
    case get_change(changeset, :project_path) || get_field(changeset, :project_path) do
      nil ->
        changeset

      "" ->
        changeset |> put_change(:project_path, nil)

      path when is_binary(path) ->
        put_change(changeset, :project_path, Path.expand(path))
    end
  end

  defp refresh_git_metadata(changeset) do
    path = get_change(changeset, :project_path) || get_field(changeset, :project_path)

    if is_binary(path) and path != "" do
      put_change(changeset, :git_metadata, SymphonyElixir.Git.info(path))
    else
      changeset
    end
  end

  defp validate_optional_priority(changeset) do
    validate_change(changeset, :priority, fn :priority, priority ->
      cond do
        is_nil(priority) -> []
        is_integer(priority) and priority in 1..4 -> []
        true -> [priority: "must be between 1 and 4"]
      end
    end)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec workspace_modes() :: [String.t()]
  def workspace_modes, do: @workspace_modes
end
