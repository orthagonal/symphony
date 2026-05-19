defmodule SymphonyElixir.Tracker.Local do
  @moduledoc """
  SQLite-backed tracker adapter for personal/local task management.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tasks

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    active_states = Config.settings!().tracker.active_states
    {:ok, Tasks.list_issues_in_states(active_states)}
  rescue
    error -> {:error, error}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    {:ok, Tasks.list_issues_in_states(state_names)}
  rescue
    error -> {:error, error}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    {:ok, Tasks.list_issues_by_ids(issue_ids)}
  rescue
    error -> {:error, error}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, task_id} <- parse_issue_id(issue_id),
         _event <- Tasks.add_comment!(task_id, body) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, task_id} <- parse_issue_id(issue_id),
         _task <- Tasks.update_status!(task_id, state_name) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp parse_issue_id(issue_id) do
    case Integer.parse(issue_id) do
      {task_id, ""} when task_id > 0 -> {:ok, task_id}
      _ -> {:error, :invalid_issue_id}
    end
  end
end
