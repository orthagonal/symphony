defmodule SymphonyElixir.AgentDispatch do
  @moduledoc """
  Routes task dispatch to Cursor, Ollama, Codex, or Zed based on task fields.
  """

  require Logger

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Tasks
  alias SymphonyElixir.Tasks.Task

  @spec resolve(Task.t()) :: String.t()
  def resolve(%Task{} = task), do: AgentBackend.resolve(task)

  @spec start_async(integer(), keyword()) :: :ok
  def start_async(task_id, opts \\ []) when is_integer(task_id) do
    task = Tasks.get!(task_id)
    backend = resolve(task)

    dispatcher(backend).start_async(task_id, opts)
  end

  @spec run(integer(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def run(task_id, opts \\ []) when is_integer(task_id) do
    task = Tasks.get!(task_id)
    backend = resolve(task)

    dispatcher(backend).run(task_id, opts)
  end

  @spec handoff(map()) :: map()
  def handoff(opts) when is_map(opts) do
    workspace = Map.get(opts, :workspace_path) || Map.get(opts, "workspace_path")
    identifier = Map.get(opts, :identifier) || Map.get(opts, "identifier") || "TASK"
    backend = Map.get(opts, :backend) || Map.get(opts, "backend") || "cursor"

    base =
      case backend do
        "cursor" ->
          SymphonyElixir.Cursor.handoff(%{workspace_path: workspace, identifier: identifier})

        "ollama" ->
          %{
            workspace_path: workspace,
            backend: "ollama",
            agent_installed: true,
            agent_authenticated: :ok,
            instructions: ollama_instructions(),
            agent_command: nil,
            open_command: nil,
            workspace_file: nil
          }

        "codex" ->
          %{
            workspace_path: workspace,
            backend: "codex",
            agent_installed: codex_available?(),
            agent_authenticated: if(codex_available?(), do: :ok, else: {:error, "codex not on PATH"}),
            agent_path: System.find_executable("codex"),
            instructions: codex_instructions(),
            agent_command: codex_command_preview(),
            open_command: nil,
            workspace_file: nil
          }

        "zed" ->
          zed = SymphonyElixir.Zed.handoff(workspace)

          Map.merge(zed, %{
            backend: "zed",
            workspace_path: workspace,
            instructions: zed_instructions(zed)
          })

        _ ->
          SymphonyElixir.Cursor.handoff(%{workspace_path: workspace, identifier: identifier})
      end

    Map.put(base, :backend, backend)
  end

  defp dispatcher("cursor"), do: SymphonyElixir.Cursor.Dispatch
  defp dispatcher("ollama"), do: SymphonyElixir.LocalDispatch
  defp dispatcher("codex"), do: SymphonyElixir.Codex.Dispatch
  defp dispatcher("zed"), do: SymphonyElixir.Zed.Dispatch
  defp dispatcher(_), do: SymphonyElixir.Cursor.Dispatch

  defp codex_available? do
    is_binary(System.find_executable("codex")) or
      match?({:ok, _}, SymphonyElixir.Config.settings())
  end

  defp codex_command_preview do
    case SymphonyElixir.Config.settings() do
      {:ok, settings} -> settings.codex.command
      _ -> "codex app-server"
    end
  end

  defp codex_instructions do
    """
    Dispatch runs your local Codex install (`codex app-server`) in the task workspace.
    Ensure `codex` is on PATH and logged in. Symphony reuses the same app-server client as the Linear orchestrator.
    """
    |> String.trim()
  end

  defp ollama_instructions do
    """
    Local-only dispatch uses Ollama (#{SymphonyElixir.Ollama.model()}) to implement the task in the workspace.
    No Cursor or Codex CLI is started.
    """
    |> String.trim()
  end

  defp zed_instructions(zed) do
    if zed[:agent_installed] do
      """
      Dispatch runs Zed's headless `eval-cli` in the task workspace.
      Set `ZED_COMMAND` if eval-cli is not on PATH. Configure model in WORKFLOW.md under `zed.model`.
      """
    else
      """
      Zed eval-cli not found. Build from zed repo (`cargo build --release -p eval_cli`) or set ZED_COMMAND to the binary path.
      """
    end
    |> String.trim()
  end
end
