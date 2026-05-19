defmodule Mix.Tasks.Symphony.Run do
  @shortdoc "Run Symphony with WORKFLOW.md (recommended on Windows with local SQLite tasks)"

  @moduledoc """
  Starts Symphony using the Mix environment so SQLite/exqlite works reliably.

      mix symphony.run ./WORKFLOW.md --port 4321 --i-understand-that-this-will-be-running-without-the-usual-guardrails
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    workflow_path =
      case OptionParser.parse(args, strict: []) do
        {_opts, [path | _], _} -> Path.expand(path)
        _ -> Path.expand("WORKFLOW.md", File.cwd!())
      end

    if File.regular?(workflow_path) do
      Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)
    end

    Mix.Task.run("app.start")
    SymphonyElixir.CLI.main(args)
  end
end
