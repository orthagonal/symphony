defmodule SymphonyElixir.Git do
  @moduledoc """
  Reads git metadata from a project directory (for per-task repo assignment).
  """

  @type info :: %{
          optional(String.t()) => String.t() | boolean() | nil
        }

  @spec info(Path.t() | nil) :: map() | nil
  def info(nil), do: nil
  def info(""), do: nil

  def info(path) when is_binary(path) do
    root = Path.expand(path)

    unless File.dir?(root) do
      %{"error" => "directory not found", "path" => root}
    else
      case inside_work_tree?(root) do
        false ->
          %{"root" => root, "git" => false, "error" => "not a git repository"}

        true ->
          %{
            "git" => true,
            "root" => root,
            "branch" => git_output(root, ["branch", "--show-current"]),
            "commit" => git_output(root, ["rev-parse", "HEAD"]),
            "commit_short" => git_output(root, ["rev-parse", "--short", "HEAD"]),
            "origin" => git_remote_origin(root),
            "dirty" => dirty?(root),
            "status_summary" => status_summary(root)
          }
      end
    end
  end

  @spec format_summary(map() | nil) :: String.t()
  def format_summary(nil), do: "No project folder"

  def format_summary(%{"git" => false} = meta) do
    "Not a git repo: #{meta["root"] || "?"}"
  end

  def format_summary(%{"error" => error}) when is_binary(error), do: error

  def format_summary(meta) when is_map(meta) do
    branch = meta["branch"] || "detached"
    short = meta["commit_short"] || String.slice(meta["commit"] || "", 0, 7)
    origin = meta["origin"]
    dirty = if meta["dirty"], do: " (dirty)", else: ""

    base = "#{branch} @ #{short}#{dirty}"

    if is_binary(origin) and origin != "" do
      base <> " · #{origin}"
    else
      base
    end
  end

  defp inside_work_tree?(root) do
    case git_cmd(root, ["rev-parse", "--is-inside-work-tree"]) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp dirty?(root) do
    case git_cmd(root, ["status", "--porcelain"]) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp status_summary(root) do
    case git_cmd(root, ["status", "--porcelain"]) do
      {output, 0} ->
        lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        case length(lines) do
          0 -> "clean"
          n -> "#{n} changed file(s)"
        end

      _ ->
        nil
    end
  end

  defp git_remote_origin(root) do
    case git_cmd(root, ["remote", "get-url", "origin"]) do
      {output, 0} ->
        output |> String.trim() |> empty_to_nil()

      _ ->
        nil
    end
  end

  defp git_output(root, args) do
    case git_cmd(root, args) do
      {output, 0} -> output |> String.trim() |> empty_to_nil()
      _ -> nil
    end
  end

  defp git_cmd(root, args) do
    System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
