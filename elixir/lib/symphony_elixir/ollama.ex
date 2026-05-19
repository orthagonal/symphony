defmodule SymphonyElixir.Ollama do
  @moduledoc """
  Lightweight client for local Ollama chat completions.

  Model resolution order:
  1. `OLLAMA_MODEL` env var (aliases like `qwen2.5-code:7b` → `qwen2.5-coder:7b`)
  2. Default `qwen2.5-coder:7b` when installed
  3. First installed match from preferred list
  4. First model returned by Ollama `/api/tags`
  """

  @default_base_url "http://127.0.0.1:11434"
  @default_model "qwen2.5-coder:7b"
  @cache_key {__MODULE__, :resolved_model}
  @cache_ttl_seconds 60

  @model_aliases %{
    "qwen2.5-code:7b" => "qwen2.5-coder:7b",
    "qwen2.5-code" => "qwen2.5-coder:7b"
  }

  @preferred_models ~w(
    qwen2.5-coder:7b
    qwen2.5-code:7b
    qwen3:8b
    qwen3
    qwen2.5:7b
    llama3.2
  )

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec chat([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    base_url = Keyword.get(opts, :base_url, base_url())
    model = Keyword.get(opts, :model, model()) |> normalize_model_name()
    timeout = Keyword.get(opts, :timeout, 120_000)

    case do_chat(base_url, model, messages, timeout) do
      {:error, {:ollama_http_error, 404, %{"error" => error}}} = err when is_binary(error) ->
        if not Keyword.get(opts, :retried, false) and model_missing?(error) do
          bust_model_cache()
          fallback = pick_model(list_installed_models())

          chat(messages,
            base_url: base_url,
            timeout: timeout,
            model: fallback,
            retried: true
          )
        else
          err
        end

      other ->
        other
    end
  end

  @spec summarize_task(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize_task(task, opts \\ []) when is_map(task) do
    events = Map.get(task, :events, [])

    event_lines =
      events
      |> Enum.take(-40)
      |> Enum.map_join("\n", fn event ->
        ts = format_ts(Map.get(event, :inserted_at))
        kind = Map.get(event, :kind, "event")
        msg = Map.get(event, :message, "")
        "[#{ts}] #{kind}: #{msg}"
      end)

    user = """
    Summarize this agent task for a phone dashboard. Be concise (under 200 words).

    Title: #{task[:title] || task["title"]}
    Status: #{task[:status] || task["status"]}
    Description:
    #{task[:body] || task["body"] || "(none)"}

    Recent log:
    #{if event_lines == "", do: "(no events yet)", else: event_lines}
    """

    chat(
      [
        %{
          role: "system",
          content:
            "You are a local assistant for Symphony agent tasks. Reply in plain markdown."
        },
        %{role: "user", content: user}
      ],
      opts
    )
  end

  @spec plan_task(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def plan_task(task, opts \\ []) when is_map(task) do
    user = """
    Turn this task into a short implementation plan for a human using Cursor Composer.

    Title: #{task[:title] || task["title"]}
    Description:
    #{task[:body] || task["body"] || "(none)"}

    Output:
    1. Goal (one sentence)
    2. Steps (numbered, max 8)
    3. Risks / unknowns (bullets)
    4. Suggested Cursor focus (one paragraph)
    """

    chat(
      [
        %{
          role: "system",
          content: "You plan tasks for Cursor Composer 2. Be practical and brief."
        },
        %{role: "user", content: user}
      ],
      opts
    )
  end

  @spec review_checklist(map(), keyword()) ::
          {:ok, %{summary: String.t(), items: String.t()}} | {:error, term()}
  def review_checklist(task, opts \\ []) when is_map(task) do
    user = """
    An autonomous agent finished this task. Write a short summary and a manual review checklist for the human owner.

    Title: #{task[:title] || task["title"]}
    Description:
    #{task[:body] || task["body"] || "(none)"}
    Project: #{task[:project_path] || task["project_path"] || "(default)"}
    Workspace: #{task[:workspace_path] || task["workspace_path"] || "—"}

    Recent log:
    #{task[:log] || "(none)"}

    Reply in exactly this format (no extra sections):
    SUMMARY:
    <2-4 sentences>
    CHECKLIST:
    - <specific thing to verify by hand>
  """

    with {:ok, text} <-
           chat(
             [
               %{
                 role: "system",
                 content:
                   "You write concise manual QA checklists for a solo developer. Each checklist line must be actionable."
               },
               %{role: "user", content: user}
             ],
             opts
           ) do
      {:ok, parse_review_response(text)}
    end
  end

  defp parse_review_response(text) when is_binary(text) do
    parts = String.split(text, ~r/^CHECKLIST:\s*/m, parts: 2)

    {summary, checklist} =
      case parts do
        [left, right] ->
          summary =
            left
            |> String.replace(~r/^SUMMARY:\s*/i, "")
            |> String.trim()

          {summary, String.trim(right)}

        _ ->
          {String.trim(text), "- Review the task changes in git\n- Confirm the workspace is clean"}
      end

    %{summary: summary, items: checklist}
  end

  @spec decompose_task_group(String.t(), keyword()) ::
          {:ok, [%{title: String.t(), body: String.t()}]} | {:error, term()}
  def decompose_task_group(description, opts \\ []) when is_binary(description) do
    user = """
    Break this large task into 3–12 small, independent subtasks suitable for a small local coding model (Ollama) to implement one at a time overnight.

    Parent task:
    #{description}

    Reply with ONLY a JSON array (no markdown fences), each element:
    {"title": "short title", "body": "detailed instructions for that subtask"}
    """

    with {:ok, text} <-
           chat(
             [
               %{
                 role: "system",
                 content:
                   "You decompose software tasks into ordered subtasks. Output valid JSON only."
               },
               %{role: "user", content: user}
             ],
             Keyword.merge([timeout: 180_000], opts)
           ),
         {:ok, chunks} <- parse_task_group_json(text) do
      {:ok, chunks}
    end
  end

  @spec implement_task(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def implement_task(task, opts \\ []) when is_map(task) do
    workspace = task[:workspace_path] || task["workspace_path"] || "."
    brief_path = Path.join(workspace, "SYMPHONY_TASK.md")

    brief =
      if File.exists?(brief_path) do
        File.read!(brief_path)
      else
        """
        Title: #{task[:title] || task["title"]}
        Description:
        #{task[:body] || task["body"] || "(none)"}
        """
      end

    user = """
    You are implementing a software task in the workspace at #{workspace}.
    Read the brief below and produce a concrete implementation plan with file paths and code blocks.

    If you cannot modify files directly, output each file as:
    FILE: relative/path
    ```
    ...contents...
    ```

    Brief:
    #{brief}
    """

    chat(
      [
        %{
          role: "system",
          content:
            "You are a local coding assistant. Be specific about files and changes. Prefer small, correct diffs."
        },
        %{role: "user", content: user}
      ],
      Keyword.merge([timeout: 300_000], opts)
    )
  end

  defp parse_task_group_json(text) when is_binary(text) do
    json =
      text
      |> String.trim()
      |> strip_json_fences()

    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        chunks =
          Enum.map(list, fn
            %{"title" => title, "body" => body} when is_binary(title) and is_binary(body) ->
              %{title: String.trim(title), body: String.trim(body)}

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        if chunks == [] do
          {:error, :empty_task_group_json}
        else
          {:ok, chunks}
        end

      {:error, reason} ->
        {:error, {:invalid_task_group_json, reason, text}}
    end
  end

  defp strip_json_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/m, "")
    |> String.replace(~r/```\s*$/m, "")
    |> String.trim()
  end

  @spec classify_difficulty(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def classify_difficulty(description, opts \\ []) when is_binary(description) do
    chat(
      [
        %{
          role: "system",
          content: "Classify task difficulty as easy, medium, or hard with one sentence why."
        },
        %{role: "user", content: description}
      ],
      opts
    )
  end

  @spec base_url() :: String.t()
  def base_url do
    env("OLLAMA_HOST") || env("OLLAMA_BASE_URL") || @default_base_url
  end

  @spec model() :: String.t()
  def model do
    case env("OLLAMA_MODEL") do
      name when is_binary(name) ->
        normalize_model_name(name)

      _ ->
        if @default_model in list_installed_models() do
          @default_model
        else
          cached_or_resolve_model()
        end
    end
  end

  @spec list_installed_models() :: [String.t()]
  def list_installed_models do
    case Req.get("#{base_url()}/api/tags", receive_timeout: 10_000) do
      {:ok, %{status: status, body: %{"models" => models}}} when status in 200..299 ->
        models
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  @spec bust_model_cache() :: :ok
  def bust_model_cache do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp do_chat(base_url, model, messages, timeout) do
    body = %{model: model, messages: messages, stream: false}

    case Req.post("#{base_url}/api/chat", json: body, receive_timeout: timeout) do
      {:ok, %{status: status, body: %{"message" => %{"content" => content}}}}
      when status in 200..299 and is_binary(content) ->
        {:ok, String.trim(content)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:ollama_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cached_or_resolve_model do
    now = System.system_time(:second)

    case safe_persistent_get(@cache_key) do
      {name, expires_at} when is_binary(name) and expires_at > now ->
        name

      _ ->
        resolve_and_cache_model(now)
    end
  end

  defp resolve_and_cache_model(now) do
    installed = list_installed_models()
    name = pick_model(installed) |> normalize_model_name()
    expires_at = now + @cache_ttl_seconds
    :persistent_term.put(@cache_key, {name, expires_at})
    name
  end

  defp pick_model(installed) when is_list(installed) do
    preferred =
      Enum.find(@preferred_models, fn preferred ->
        Enum.any?(installed, fn name ->
          name == preferred or String.starts_with?(name, preferred <> ":")
        end)
      end)

    preferred || List.first(installed) || @default_model
  end

  defp normalize_model_name(name) when is_binary(name) do
    Map.get(@model_aliases, name, name)
  end

  defp model_missing?(error), do: String.contains?(String.downcase(error), "not found")

  defp safe_persistent_get(key) do
    :persistent_term.get(key)
  rescue
    ArgumentError -> :missing
  end

  defp env(key) do
    case System.get_env(key) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other) when not is_nil(other), do: to_string(other)
  defp format_ts(_), do: "?"
end
