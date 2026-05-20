defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Supported dashboard task agent backends and resolution helpers.
  """

  @backends ~w(cursor ollama codex zed)
  @default_backend "cursor"
  @local_only_backend "ollama"

  @spec backends() :: [String.t()]
  def backends, do: @backends

  @spec default() :: String.t()
  def default, do: @default_backend

  @spec resolve(map()) :: String.t()
  def resolve(%{local_only: true}), do: @local_only_backend

  def resolve(%{assigned_agent: agent}) when is_binary(agent) do
    agent |> normalize() |> validate_or_default()
  end

  def resolve(_task), do: @default_backend

  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(agent) when is_binary(agent) do
    agent
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  @spec valid?(String.t() | nil) :: boolean()
  def valid?(agent) do
    case normalize(agent) do
      nil -> false
      value -> value in @backends
    end
  end

  defp validate_or_default(nil), do: @default_backend
  defp validate_or_default(value) when value in @backends, do: value
  defp validate_or_default(_), do: @default_backend

  @spec label(String.t()) :: String.t()
  def label("cursor"), do: "Cursor (cursor-agent)"
  def label("ollama"), do: "Ollama (local)"
  def label("codex"), do: "Codex (app-server)"
  def label("zed"), do: "Zed (eval-cli)"
  def label(other), do: other
end
