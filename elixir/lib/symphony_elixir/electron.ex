defmodule SymphonyElixir.Electron do
  @moduledoc """
  Facade for the automated Electron debug session managed by `SymphonyElixir.Electron.Session`.
  """

  alias SymphonyElixir.Electron.Session

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []), do: Session.build(opts)

  @spec launch(keyword()) :: {:ok, map()} | {:error, term()}
  def launch(opts \\ []), do: Session.launch(opts)

  @spec build_and_launch(keyword()) :: {:ok, map()} | {:error, term()}
  def build_and_launch(opts \\ []), do: Session.build_and_launch(opts)

  @spec status() :: map()
  def status, do: Session.status()

  @spec tail_log(pos_integer()) :: {:ok, map()} | {:error, term()}
  def tail_log(lines \\ 50), do: Session.tail_log(lines)

  @spec inspect_targets() :: {:ok, map()} | {:error, term()}
  def inspect_targets, do: Session.inspect_targets()

  @spec stop() :: {:ok, map()} | {:error, term()}
  def stop, do: Session.stop()
end
