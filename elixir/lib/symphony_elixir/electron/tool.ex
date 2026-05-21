defmodule SymphonyElixir.Electron.Tool do
  @moduledoc """
  Client-side `electron_debug` tool for Codex app-server sessions.
  """

  alias SymphonyElixir.Electron.Session
  alias SymphonyElixir.Electron.Tool.DynamicToolHelpers

  @tool_name "electron_debug"
  @supported_actions ~w(build launch build_and_launch status logs inspect stop)

  @description """
  Manage an Electron debug session: compile the game, launch with inspect/CDP ports, read logs, list debug targets, and stop the process.

  Typical flow: `build_and_launch` → reproduce issue → `logs` / `inspect` → `stop`.
  Use `force: true` to stop a running session before relaunching.
  """

  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => @supported_actions,
        "description" => "Pipeline step to run."
      },
      "game_name" => %{
        "type" => "string",
        "description" => "Game name passed to scripts/compileGame (overrides WORKFLOW electron.game_name)."
      },
      "game_folder" => %{
        "type" => "string",
        "description" => "Absolute path to the game repo (overrides GAME_FOLDER / electron.game_folder)."
      },
      "lines" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 500,
        "description" => "Number of log lines to return for the logs action."
      },
      "force" => %{
        "type" => "boolean",
        "description" => "When true, stop a running session before build/launch."
      }
    }
  }

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => @tool_name,
      "description" => String.trim(@description),
      "inputSchema" => @input_schema
    }
  end

  @spec execute(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(arguments, opts \\ []) do
    session = Keyword.get(opts, :session_module, Session)

    with {:ok, action, call_opts} <- normalize_arguments(arguments) do
      case action do
        "build" -> session.build(call_opts)
        "launch" -> session.launch(call_opts)
        "build_and_launch" -> session.build_and_launch(call_opts)
        "status" -> {:ok, session.status()}
        "logs" -> session.tail_log(Keyword.get(call_opts, :lines, 50))
        "inspect" -> session.inspect_targets()
        "stop" -> session.stop()
      end
    end
  end

  @spec dynamic_tool_response({:ok, map()} | {:error, term()}) :: map()
  def dynamic_tool_response({:ok, payload}) do
    DynamicToolHelpers.success(payload)
  end

  def dynamic_tool_response({:error, reason}) do
    DynamicToolHelpers.failure(tool_error_payload(reason))
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    action =
      Map.get(arguments, "action") || Map.get(arguments, :action)
      |> case do
        action when is_binary(action) -> String.trim(action)
        _ -> nil
      end

    if action in @supported_actions do
      opts =
        []
        |> maybe_put(:game_name, Map.get(arguments, "game_name") || Map.get(arguments, :game_name))
        |> maybe_put(:game_folder, Map.get(arguments, "game_folder") || Map.get(arguments, :game_folder))
        |> maybe_put(:force, Map.get(arguments, "force") || Map.get(arguments, :force))
        |> maybe_put(:lines, Map.get(arguments, "lines") || Map.get(arguments, :lines))

      {:ok, action, opts}
    else
      {:error, {:invalid_action, action, @supported_actions}}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp tool_error_payload({:invalid_action, action, supported}) do
    %{
      "error" => %{
        "message" => "`electron_debug.action` must be one of #{inspect(supported)}; got #{inspect(action)}."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`electron_debug` expects a JSON object with an `action` field."
      }
    }
  end

  defp tool_error_payload({:busy, status, message}) when is_binary(message) do
    %{"error" => %{"message" => message, "status" => status}}
  end

  defp tool_error_payload({:busy, status}) do
    %{"error" => %{"message" => "Electron session is busy.", "status" => status}}
  end

  defp tool_error_payload({:build_failed, build_result}) do
    %{
      "error" => %{
        "message" => "Game build failed.",
        "build" => build_result
      }
    }
  end

  defp tool_error_payload({:launch_failed, reason}) do
    %{
      "error" => %{
        "message" => "Electron launch failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:invalid_game_folder, folder}) do
    %{
      "error" => %{
        "message" => "Invalid or missing game folder. Set electron.game_folder in WORKFLOW.md or GAME_FOLDER.",
        "game_folder" => folder
      }
    }
  end

  defp tool_error_payload({:missing_game_name, message}) do
    %{"error" => %{"message" => message}}
  end

  defp tool_error_payload({:inspect_failed, reason}) do
    %{
      "error" => %{
        "message" => "Could not fetch CDP targets. Is remote debugging enabled and the app running?",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:invalid_state, status, message}) do
    %{"error" => %{"message" => message, "status" => status}}
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Electron debug tool failed.",
        "reason" => inspect(reason)
      }
    }
  end
end

defmodule SymphonyElixir.Electron.Tool.DynamicToolHelpers do
  @moduledoc false

  @spec success(map()) :: map()
  def success(payload) when is_map(payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => true,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  @spec failure(map()) :: map()
  def failure(payload) when is_map(payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
