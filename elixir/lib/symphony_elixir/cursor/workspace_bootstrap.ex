defmodule SymphonyElixir.Cursor.WorkspaceBootstrap do
  @moduledoc """
  Seeds a per-task workspace from the task's project folder (or WORKFLOW default).
  """

  require Logger

  alias SymphonyElixir.{Config, Git, PathSafety, Tasks}
  alias SymphonyElixir.Tasks.Task

  @exclude_when_copying ~w(_build deps node_modules .git undefined data erl_crash.dump)

  @spec bootstrap(Path.t(), Task.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def bootstrap(workspace, %Task{} = task, opts \\ []) when is_binary(workspace) do
    git_batch = Keyword.get(opts, :git_batch)

    with {:ok, workspace} <- resolve_workspace_root(workspace, task),
         :ok <- seed_repo(workspace, task),
         {:ok, refreshed} <- refresh_git_metadata(task, workspace),
         :ok <- write_task_files(workspace, refreshed, git_batch) do
      {:ok, workspace}
    end
  end

  defp resolve_workspace_root(_workspace, %Task{workspace_mode: "linked", project_path: path})
       when is_binary(path) and path != "" do
    PathSafety.canonicalize(Path.expand(path))
  end

  defp resolve_workspace_root(workspace, _task) when is_binary(workspace) do
    PathSafety.canonicalize(workspace)
  end

  defp seed_repo(workspace, %Task{} = task) do
    case task.workspace_mode do
      "linked" ->
        :ok

      _ ->
        case project_seed_source(task) do
          {:error, _} = err ->
            err

          {:copy, seed_path} ->
            copy_seed_into(workspace, seed_path)

          {:git, url} ->
            git_clone_into(workspace, url)

          :none ->
            :ok
        end
    end
  end

  defp project_seed_source(%Task{project_path: path}) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:copy, expanded}
    else
      {:error, {:project_path_not_found, expanded}}
    end
  end

  defp project_seed_source(_task) do
    global_seed_settings()
  end

  defp global_seed_settings do
    settings = Config.settings!()
    mode = normalize_mode(settings.workspace.seed_mode)
    seed_path = resolve_global_seed_path(settings.workspace.seed_path)

    cond do
      mode == "git" and is_binary(settings.workspace.seed_git_url) and
          settings.workspace.seed_git_url != "" ->
        {:git, settings.workspace.seed_git_url}

      mode in ["copy", ""] and is_binary(seed_path) ->
        {:copy, seed_path}

      mode == "copy" ->
        {:error, {:seed_path_missing, "workspace.seed_path is not set"}}

      true ->
        :none
    end
  rescue
    _ -> fallback_seed_settings()
  end

  defp fallback_seed_settings do
    case env_seed_path() do
      path when is_binary(path) -> {:copy, path}
      _ -> :none
    end
  end

  defp copy_seed_into(workspace, seed_path) do
    unless File.dir?(seed_path) do
      {:error, {:seed_path_not_found, seed_path}}
    else
      if workspace_empty?(workspace) do
        do_copy_seed(workspace, seed_path)
      else
        Logger.info("WorkspaceBootstrap: #{workspace} already has files; skipping repo copy")
        :ok
      end
    end
  end

  defp do_copy_seed(workspace, seed_path) do
    seed_path
    |> File.ls!()
    |> Enum.reject(&(&1 in @exclude_when_copying))
    |> Enum.each(fn name ->
      src = Path.join(seed_path, name)
      dest = Path.join(workspace, name)
      File.cp_r!(src, dest)
    end)

    :ok
  rescue
    error -> {:error, {:copy_seed_failed, error}}
  end

  defp git_clone_into(workspace, url) do
    if workspace_empty?(workspace) do
      case System.cmd("git", ["clone", "--depth", "1", url, workspace],
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {_, 0} -> :ok
        {output, code} -> {:error, {:git_clone_failed, code, output}}
      end
    else
      :ok
    end
  end

  defp refresh_git_metadata(task, workspace) do
    git_root =
      case task.project_path do
        path when is_binary(path) and path != "" -> Path.expand(path)
        _ -> workspace
      end

    meta = Git.info(git_root)
    {:ok, Tasks.update!(task.id, %{git_metadata: meta})}
  rescue
    error -> {:error, error}
  end

  defp write_task_files(workspace, %Task{} = task, git_batch \\ nil) do
    identifier = "TASK-#{task.id}"
    plan = latest_plan(task)
    dashboard = dashboard_url(task)
    status_api = Tasks.api_status_url(task.id)
    complete_hint = complete_task_instructions(task.id, status_api)
    git_section = format_git_section(task)
    batch_section = format_git_batch_section(git_batch, task)

    task_md = """
    # #{identifier}: #{task.title}

    **Status:** #{task.status}
    **Dashboard:** #{dashboard || "http://127.0.0.1:4321/tasks/#{task.id}"}
    **Workspace mode:** #{task.workspace_mode}
    **Project folder:** #{task.project_path || workspace}

    ## Git

    #{git_section}

    #{batch_section}

    ## Description

    #{task.body || "_No description._"}

    ## Plan (from Ollama)

    #{plan || "_Run “Plan for Cursor” on the dashboard, then click Prepare workspace again._"}

    ## Mark complete

    #{complete_hint}
    """

    rules = """
    You are working on Symphony task #{identifier}.

    - Read `SYMPHONY_TASK.md` in this folder first.
    - Project root: #{task.project_path || workspace}
    - #{git_rules_line(task)}
    - #{git_batch_rules_line(git_batch)}
    - Do not run `mix symphony.task` from an isolated workspace copy (not a full Symphony runtime).
    - When finished, use the API in SYMPHONY_TASK.md to set status **review**, or rely on Symphony auto-marking **review** after headless agent success.
    """

    workspace_file = %{
      "folders" => [%{"name" => identifier, "path" => "."}],
      "settings" => %{
        "files.exclude" => %{
          "**/_build" => true,
          "**/deps" => true
        }
      }
    }

    rules_path = Path.join(workspace, ".cursor/rules/symphony-task.mdc")
    File.mkdir_p!(Path.dirname(rules_path))
    File.write!(Path.join(workspace, "SYMPHONY_TASK.md"), task_md)
    File.write!(rules_path, rules)
    File.write!(Path.join(workspace, "#{identifier}.code-workspace"), Jason.encode!(workspace_file, pretty: true))

    :ok
  rescue
    error -> {:error, {:write_task_files_failed, error}}
  end

  defp format_git_section(%Task{git_metadata: meta}) when is_map(meta) do
    if meta["git"] == false do
      "_This folder is not a git repository._"
    else
      """
      - **Summary:** #{Git.format_summary(meta)}
      - **Branch:** #{meta["branch"] || "—"}
      - **Commit:** `#{meta["commit"] || "—"}`
      - **Origin:** #{meta["origin"] || "—"}
      - **Working tree:** #{meta["status_summary"] || "—"}#{if meta["dirty"], do: " (uncommitted changes)", else: ""}
      """
      |> String.trim()
    end
  end

  defp format_git_section(_), do: "_No git metadata (set a project folder on the task)._"

  defp git_rules_line(%Task{git_metadata: %{"git" => true} = meta}) do
    "Git: #{Git.format_summary(meta)} — respect current branch and uncommitted state."
  end

  defp git_rules_line(_), do: "No git metadata for this project."

  defp format_git_batch_section(nil, _task), do: ""

  defp format_git_batch_section(batch, %Task{} = task) when is_map(batch) do
    role = batch[:role] || batch["role"]
    branch = batch[:branch] || batch["branch"]
    index = batch[:index] || batch["index"]
    total = batch[:total] || batch["total"]

    """
    ## Queue git batch

    - **Role:** `#{role}` (#{index}/#{total} in this repo)
    - **Shared branch:** `#{branch}`
    - **Commit message:** include task id `TASK-#{task.id}` and title: #{task.title}

    ### Rules

    - **solo / first:** save `ORIGINAL_BRANCH`, create `#{branch}`, switch to it.
    - **middle:** stay on `#{branch}`; commit only this task's changes (message includes task name).
    - **last:** commit this task's changes, then `git switch` back to `ORIGINAL_BRANCH`.
    - **solo:** same as first+last in one task.
    - Commit only generated/changed code and READMEs for this task. Leave the workspace clean (no stray edits, no secrets, no build artifacts).
  """
    |> String.trim()
  end

  defp git_batch_rules_line(nil), do: "Follow git workflow in SYMPHONY_TASK.md when in a git repo."

  defp git_batch_rules_line(batch) when is_map(batch) do
    branch = batch[:branch] || batch["branch"]
    role = batch[:role] || batch["role"]
    "Queue git: role=#{role}, shared branch #{branch}, restore original branch when batch role is last or solo."
  end

  defp latest_plan(%Task{events: events}) when is_list(events) do
    events
    |> Enum.find(fn e -> e.kind in ["plan", "llm_plan"] end)
    |> case do
      nil -> nil
      event -> event.message
    end
  end

  defp latest_plan(_), do: nil

  defp workspace_empty?(workspace) do
    case File.ls(workspace) do
      {:ok, []} -> true
      {:ok, names} -> Enum.all?(names, &(&1 in [".", ".."]))
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp resolve_global_seed_path(nil), do: env_seed_path() || default_symphony_repo_path()
  defp resolve_global_seed_path(""), do: env_seed_path() || default_symphony_repo_path()
  defp resolve_global_seed_path(path), do: Path.expand(path)

  defp default_symphony_repo_path do
    cwd = File.cwd!()

    candidates = [
      Path.expand(Path.join(cwd, "..")),
      Path.expand(Path.join(cwd, "../..")),
      Path.expand("C:/GitHub/symphony")
    ]

    Enum.find(candidates, &(File.exists?(Path.join(&1, "elixir/mix.exs"))))
  end

  defp env_seed_path do
    case System.get_env("SYMPHONY_WORKSPACE_SEED") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp normalize_mode(nil), do: "copy"
  defp normalize_mode(""), do: "copy"
  defp normalize_mode(mode) when is_binary(mode), do: String.downcase(mode)
  defp normalize_mode(_), do: "copy"

  defp dashboard_url(task) do
    case Tasks.to_issue(task).url do
      url when is_binary(url) -> url
      _ -> nil
    end
  end

  defp complete_task_instructions(_task_id, nil) do
    """
    Symphony will mark this task **review** automatically when cursor-agent finishes successfully (dashboard Dispatch).

    After you verify the work on the Reviews screen, click **Done** or **Failed**, or **Resubmit** with notes.
    """
  end

  defp complete_task_instructions(_task_id, status_api) do
    """
    Symphony marks this task **review** automatically when headless `cursor-agent` exits successfully.

    Optional manual API (from PowerShell or bash):

    ```bash
    curl -X POST "#{status_api}" -H "Content-Type: application/json" -d "{\\"status\\":\\"review\\"}"
    ```
    """
  end
end
