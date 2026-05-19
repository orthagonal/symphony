defmodule SymphonyElixir.Cursor do
  @moduledoc """
  Cursor IDE / Agent CLI handoff (opens folder or runs `cursor-agent`).
  """

  require Logger

  @agent_prompt """
  Read SYMPHONY_TASK.md in this workspace and implement the task. Work only in this directory. When finished, summarize what you changed.
  """

  @spec handoff(map()) :: map()
  def handoff(opts) when is_map(opts) do
    workspace = Map.get(opts, :workspace_path) || Map.get(opts, "workspace_path")
    identifier = Map.get(opts, :identifier) || Map.get(opts, "identifier") || "TASK"

    %{
      workspace_path: workspace,
      open_command: open_command(workspace),
      workspace_file: workspace_file(workspace, identifier),
      agent_command: agent_command(workspace, identifier),
      agent_installed: agent_executable() != nil,
      agent_authenticated: agent_authenticated?() == :ok,
      cursor_installed: cursor_executable() != nil,
      agent_path: agent_executable(),
      cursor_path: cursor_executable(),
      instructions: instructions(workspace, identifier)
    }
  end

  @spec open_folder(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def open_folder(path) when is_binary(path) do
    case cursor_executable() do
      nil ->
        {:error, :cursor_cli_not_found}

      exe ->
        target = Path.expand(path)

        if windows?() do
          windows_start(exe, target)
        else
          {output, status} = System.cmd(exe, [target], stderr_to_stdout: true)

          if status == 0 do
            {:ok, String.trim(output)}
          else
            {:error, {:cursor_open_failed, status, output}}
          end
        end
    end
  end

  @spec open_workspace_file(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def open_workspace_file(workspace, identifier)
      when is_binary(workspace) and is_binary(identifier) do
    workspace = Path.expand(workspace)
    ws_file = Path.join(workspace, "#{identifier}.code-workspace")
    task_md = Path.join(workspace, "SYMPHONY_TASK.md")

    target =
      cond do
        File.exists?(ws_file) -> ws_file
        File.exists?(task_md) -> task_md
        true -> workspace
      end

    open_folder(target)
  end

  @spec open_command(Path.t() | nil) :: String.t() | nil
  def open_command(nil), do: nil

  def open_command(workspace) when is_binary(workspace) do
    case cursor_executable() do
      nil -> "cursor #{inspect(workspace)}"
      exe -> "#{inspect(exe)} #{inspect(workspace)}"
    end
  end

  @spec workspace_file(Path.t() | nil, String.t()) :: String.t() | nil
  def workspace_file(nil, _identifier), do: nil

  def workspace_file(workspace, identifier) when is_binary(workspace) do
    Path.join(workspace, "#{identifier}.code-workspace")
  end

  @spec agent_command(Path.t() | nil, String.t()) :: String.t() | nil
  def agent_command(nil, _identifier), do: nil

  def agent_command(workspace, identifier) when is_binary(workspace) and is_binary(identifier) do
    exe = agent_executable() || "cursor-agent"

    ~s(cd /d #{inspect(Path.expand(workspace))} && #{inspect(exe)} --print --yolo --output-format text #{inspect(@agent_prompt)})
  end

  @spec instructions(Path.t() | nil, String.t()) :: String.t()
  def instructions(nil, _identifier) do
    """
    1. Click **Dispatch to Cursor** or prepare workspace manually.
    2. Install Cursor Agent CLI if missing: irm https://cursor.com/install?win32=true | iex
    3. When finished, the dashboard marks **review** after headless agent success — approve there or resubmit with notes.
    """
    |> String.trim()
  end

  def instructions(workspace, identifier) when is_binary(workspace) do
    ws_file = workspace_file(workspace, identifier)

    """
    1. Open folder: #{open_command(workspace)}
    2. Workspace file: #{inspect(ws_file)}
    3. Headless agent: #{agent_command(workspace, identifier)}
    4. Composer GUI: open SYMPHONY_TASK.md and paste into Composer if you prefer the UI.
    5. After the agent finishes, confirm work on the Reviews screen (`/reviews`).
    """
    |> String.trim()
  end

  @spec cursor_executable() :: Path.t() | nil
  def cursor_executable do
    env_cursor() ||
      find_existing([
        windows_cursor_path(),
        System.find_executable("cursor"),
        System.find_executable("cursor.cmd")
      ])
  end

  @spec agent_executable() :: Path.t() | nil
  def agent_executable do
    env_agent() ||
      find_existing(
        windows_agent_paths() ++
          [
            System.find_executable("agent"),
            System.find_executable("agent.exe"),
            System.find_executable("cursor-agent"),
            System.find_executable("cursor-agent.cmd")
          ]
      )
  end

  @doc """
  Snapshot of the Cursor Agent CLI login and account surfaced by `cursor-agent about` /
  `cursor-agent status` (JSON).

  Useful when Symphony is driven by Cursor headless CLI instead of Codex — token totals
  from the Codex orchestrator may be absent even though the Cursor account is active.
  """

  @spec account_snapshot() :: {:ok, map()} | {:error, term()}
  def account_snapshot do
    case agent_executable() do
      nil ->
        {:error, :cursor_agent_missing}

      exe ->
        with {:ok, about} <- decode_agent_json_cmd(exe, ["about", "--format", "json"]),
             {:ok, status} <- decode_agent_json_cmd(exe, ["status", "--format", "json"]) do
          {:ok, merge_about_and_status(about, status)}
        end
    end
  end

  @spec agent_authenticated?() :: :ok | {:error, String.t()}
  def agent_authenticated?() do
    case agent_executable() do
      nil ->
        {:error, "cursor-agent not installed"}

      exe ->
        {output, status} = run_agent_cmd(exe, ["status"], File.cwd!())

        output_lower = String.downcase(output)

        cond do
          status == 0 and
              (String.contains?(output_lower, "logged in") or
                 String.contains?(output, "✓")) ->
            :ok

          String.contains?(output_lower, "not logged in") or
              String.contains?(output_lower, "authentication required") ->
            {:error, "Not logged in. Run: #{inspect(exe)} login"}

          status != 0 ->
            {:error, String.trim(output)}

          true ->
            {:error, "Unknown auth state: #{String.slice(output, 0, 200)}"}
        end
    end
  end

  @spec run_agent(Path.t(), Path.t(), String.t(), integer()) :: :ok | {:error, term()}
  def run_agent(agent_exe, workspace, _prompt, task_id)
      when is_binary(agent_exe) and is_binary(workspace) and is_integer(task_id) do
    workspace = Path.expand(workspace)

    auth = agent_authenticated?()

    cond do
      not File.dir?(workspace) ->
        return_error(task_id, "Workspace directory does not exist: #{workspace}")

      match?({:error, _}, auth) ->
        {:error, msg} = auth
        safe_log(task_id, "agent_failed", msg)
        safe_log(task_id, "dispatch", "Run cursor-agent login in PowerShell, then Dispatch again")
        {:error, :agent_not_authenticated}

      true ->
        File.write!(Path.join(workspace, ".symphony-agent-prompt.txt"), @agent_prompt)

        safe_log(
          task_id,
          "agent_log",
          "Running cursor-agent --print in #{workspace} (auth OK)"
        )

        args = ["--print", "--yolo", "--output-format", "text", @agent_prompt]

        Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          {output, status} = run_agent_cmd(agent_exe, args, workspace)
          log_agent_output(task_id, output, status)
        end)

        :ok
    end
  end

  defp merge_about_and_status(about, status) when is_map(about) and is_map(status) do
    email =
      about["userEmail"] ||
        case Map.get(status, "userInfo") do
          %{"email" => e} when is_binary(e) -> e
          _ -> nil
        end

    %{
      email: email,
      subscription_tier: about["subscriptionTier"],
      model: about["model"],
      cli_version: about["cliVersion"],
      authenticated: truthy?(Map.get(status, "isAuthenticated")),
      auth_status: Map.get(status, "status"),
      os_platform: about["osPlatform"],
      terminal_program: about["terminalProgram"],
      shell: about["shell"]
    }
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp decode_agent_json_cmd(agent_exe, args) when is_binary(agent_exe) and is_list(args) do
    cwd = File.cwd!()
    {output, exit_status} = run_agent_cmd(agent_exe, args, cwd)
    trimmed = String.trim(output)

    cond do
      exit_status != 0 ->
        {:error, {:cursor_agent_cmd_failed, exit_status, trimmed}}

      trimmed == "" ->
        {:error, :empty_agent_output}

      true ->
        case Jason.decode(trimmed) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:ok, _} -> {:error, {:invalid_json, trimmed}}
          {:error, _} -> {:error, {:invalid_json, trimmed}}
        end
    end
  end

  defp run_agent_cmd(agent_exe, args, cwd) do
    if windows?() do
      # .cmd cannot use spawn_executable; pass path + args as separate argv to cmd /c.
      agent = normalize_executable(agent_exe)
      System.cmd("cmd.exe", ["/c", agent | args], cd: cwd, stderr_to_stdout: true)
    else
      System.cmd(agent_exe, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  defp log_agent_output(task_id, output, status) do
    output
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      if String.trim(line) != "", do: log_agent_line(task_id, line)
    end)

    if status == 0 do
      safe_log(task_id, "agent_done", "Cursor agent finished successfully")
      mark_task_for_review(task_id)
    else
      safe_log(
        task_id,
        "agent_failed",
        "Cursor agent exited #{status}. If auth failed, run: cursor-agent login"
      )
    end
  end

  defp return_error(task_id, message) do
    safe_log(task_id, "agent_failed", message)
    {:error, message}
  end

  defp mark_task_for_review(task_id) do
    alias SymphonyElixir.Tasks

    task = Tasks.get!(task_id)

    if task.status in ["done", "failed", "cancelled", "review"] do
      :ok
    else
      Tasks.update_status!(task_id, "review")
      Tasks.log_event!(task_id, "status", "Marked review automatically after cursor-agent success")
    end
  rescue
    error ->
      Logger.warning("mark_task_for_review failed task_id=#{task_id} error=#{inspect(error)}")
      safe_log(task_id, "dispatch", "Could not auto-mark review — set status on the dashboard")
  end

  defp log_agent_line(task_id, line), do: safe_log(task_id, "agent_log", String.slice(line, 0, 2000))

  defp safe_log(task_id, kind, message) do
    SymphonyElixir.Tasks.log_event!(task_id, kind, message)
  rescue
    _ -> :ok
  end

  defp windows_start(exe, target) do
    # start "" avoids blocking; GUI apps often return non-zero from System.cmd
    {output, _status} =
      System.cmd("cmd.exe", ["/c", "start", "", exe, target], stderr_to_stdout: true)

    {:ok, String.trim(output)}
  rescue
    error -> {:error, {:windows_start_failed, error}}
  end

  defp windows_agent_paths do
    local = System.get_env("LOCALAPPDATA")
    profile = System.get_env("USERPROFILE")

    [
      local && Path.join([local, "cursor-agent", "cursor-agent.cmd"]),
      local && Path.join([local, "cursor-agent", "agent.cmd"]),
      profile && Path.join([profile, ".local", "bin", "agent.cmd"]),
      profile && Path.join([profile, ".local", "bin", "agent.exe"])
    ]
  end

  defp windows_cursor_path do
    case System.get_env("LOCALAPPDATA") do
      base when is_binary(base) ->
        path = Path.join([base, "Programs", "cursor", "resources", "app", "bin", "cursor.cmd"])
        if File.regular?(path), do: path

      _ ->
        nil
    end
  end

  defp normalize_executable(path) when is_binary(path) do
    String.replace(path, "/", "\\")
  end

  defp find_existing(candidates) do
    Enum.find_value(candidates, fn
      path when is_binary(path) ->
        expanded = Path.expand(path)
        if File.regular?(expanded), do: expanded

      _ ->
        nil
    end)
  end

  defp env_cursor do
    case System.get_env("CURSOR_COMMAND") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp env_agent do
    case System.get_env("CURSOR_AGENT_COMMAND") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp windows? do
    case :os.type() do
      {:win32, _} -> true
      _ -> false
    end
  end
end
