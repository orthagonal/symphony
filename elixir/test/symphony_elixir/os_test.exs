defmodule SymphonyElixir.OSTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OS

  test "open_in_file_explorer rejects missing paths" do
    missing = Path.join(System.tmp_dir!(), "symphony-missing-#{System.unique_integer([:positive])}")
    expanded = Path.expand(missing)

    assert {:error, {:path_not_found, ^expanded}} = OS.open_in_file_explorer(missing)
  end

  test "open_in_file_explorer accepts existing directories" do
    dir = System.tmp_dir!()

    case OS.open_in_file_explorer(dir) do
      :ok -> :ok
      {:error, {:command_not_found, _}} -> :ok
      other -> flunk("unexpected result: #{inspect(other)}")
    end
  end

  @tag :skip
  test "pick_folder accepts an initial directory hint" do
    dir = System.tmp_dir!()

    case OS.pick_folder(dir) do
      {:ok, path} ->
        assert Path.expand(path) == path
        assert File.dir?(path)

      {:error, :cancelled} ->
        :ok

      {:error, {:command_not_found, _}} ->
        :ok

      other ->
        flunk("unexpected result: #{inspect(other)}")
    end
  end
end
