defmodule SymphonyElixir.Zed do
  @moduledoc """
  Zed headless agent CLI (`eval-cli`) discovery and execution helpers.
  """

  require Logger

  @agent_prompt """
  Read SYMPHONY_TASK.md in this workspace and implement the task. Work only in this directory. When finished, summarize what you changed.
  """

  @spec handoff(Path.t() | nil) :: map()
  def handoff(workspace \\ nil) do
    exe = eval_cli_executable()

    %{
      agent_installed: exe != nil,
      agent_authenticated: if(exe, do: :ok, else: {:error, "eval-cli not found"}),
      agent_path: exe,
      agent_command: agent_command(workspace, exe),
      model: model(),
      timeout_seconds: timeout_seconds()
    }
  end

  @spec eval_cli_executable() :: Path.t() | nil
  def eval_cli_executable do
    env_command() ||
      find_existing([
        System.find_executable("eval-cli"),
        System.find_executable("eval-cli.exe"),
        windows_eval_cli_paths()
      ])
  end

  @spec model() :: String.t()
  def model do
    case System.get_env("ZED_MODEL") do
      m when is_binary(m) and m != "" -> m
      _ -> config_model()
    end
  end

  @spec timeout_seconds() :: pos_integer()
  def timeout_seconds do
    case System.get_env("ZED_TIMEOUT_SECONDS") do
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> config_timeout()
        end

      _ ->
        config_timeout()
    end
  end

  @spec command() :: String.t()
  def command do
    env_command() || config_command() || "eval-cli"
  end

  @spec run_agent(Path.t(), integer(), String.t()) :: :ok | {:error, term()}
  def run_agent(workspace, task_id, prompt \\ @agent_prompt)
      when is_binary(workspace) and is_integer(task_id) do
    workspace = Path.expand(workspace)

    case eval_cli_executable() do
      nil ->
        safe_log(task_id, "agent_failed", "Zed eval-cli not found. Set ZED_COMMAND or add eval-cli to PATH.")
        {:error, :zed_cli_not_found}

      exe ->
        if File.dir?(workspace) do
          File.write!(Path.join(workspace, ".symphony-agent-prompt.txt"), prompt)

          args = [
            "--workdir",
            workspace,
            "--model",
            model(),
            "--instruction",
            prompt,
            "--timeout",
            Integer.to_string(timeout_seconds())
          ]

          safe_log(task_id, "agent_log", "Running #{exe} in #{workspace}")

          Elixir.Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            {output, status} = run_cmd(exe, args, workspace)
            log_output(task_id, output, status)
          end)

          :ok
        else
          safe_log(task_id, "agent_failed", "Workspace missing: #{workspace}")
          {:error, :workspace_missing}
        end
    end
  end

  @spec agent_command(Path.t() | nil, Path.t() | nil) :: String.t() | nil
  def agent_command(workspace, exe \\ nil) do
    exe = exe || eval_cli_executable() || command()
    ws = if is_binary(workspace), do: Path.expand(workspace), else: "."

    ~s(#{inspect(exe)} --workdir #{inspect(ws)} --model #{inspect(model())} --instruction "...")
  end

  defp run_cmd(exe, args, cwd) do
    if windows?() do
      exe = String.replace(exe, "/", "\\")
      System.cmd("cmd.exe", ["/c", exe | args], cd: cwd, stderr_to_stdout: true)
    else
      System.cmd(exe, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  defp log_output(task_id, output, status) do
    output
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      if String.trim(line) != "", do: safe_log(task_id, "agent_log", String.slice(line, 0, 2000))
    end)

    if status == 0 do
      safe_log(task_id, "agent_done", "Zed eval-cli finished successfully")
      mark_review(task_id)
    else
      safe_log(task_id, "agent_failed", "Zed eval-cli exited #{status}")
    end
  end

  defp mark_review(task_id) do
    alias SymphonyElixir.Tasks

    task = Tasks.get!(task_id)

    if task.status in ["done", "failed", "cancelled", "review"] do
      :ok
    else
      Tasks.update_status!(task_id, "review")
      Tasks.log_event!(task_id, "status", "Marked review after Zed eval-cli success")
    end
  rescue
    error -> Logger.warning("Zed mark_review failed: #{inspect(error)}")
  end

  defp config_model do
    case zed_settings() do
      %{model: m} when is_binary(m) and m != "" -> m
      _ -> "anthropic/claude-sonnet-4-6-latest"
    end
  end

  defp config_timeout do
    case zed_settings() do
      %{timeout_seconds: n} when is_integer(n) and n > 0 -> n
      _ -> 3600
    end
  end

  defp config_command do
    case zed_settings() do
      %{command: c} when is_binary(c) and c != "" -> c
      _ -> nil
    end
  end

  defp zed_settings do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} -> settings.zed
      _ -> nil
    end
  end

  defp env_command do
    case System.get_env("ZED_COMMAND") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp windows_eval_cli_paths do
    local = System.get_env("LOCALAPPDATA")
    profile = System.get_env("USERPROFILE")

    [
      local && Path.join([local, "zed", "eval-cli.exe"]),
      profile && Path.join([profile, ".zed", "bin", "eval-cli.exe"])
    ]
  end

  defp find_existing(candidates) do
    List.flatten(candidates)
    |> Enum.find_value(fn
      path when is_binary(path) ->
        expanded = Path.expand(path)
        if File.regular?(expanded), do: expanded

      _ ->
        nil
    end)
  end

  defp safe_log(task_id, kind, message) do
    SymphonyElixir.Tasks.log_event!(task_id, kind, message)
  rescue
    _ -> :ok
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end
end
