defmodule SymphonyElixir.OS do
  @moduledoc false

  @spec pick_folder(Path.t() | nil) :: {:ok, Path.t()} | {:error, :cancelled | term()}
  def pick_folder(initial \\ nil) do
    cond do
      windows?() -> pick_folder_windows(initial)
      macos?() -> pick_folder_macos()
      true -> pick_folder_unix(initial)
    end
  end

  @spec open_in_file_explorer(Path.t()) :: :ok | {:error, term()}
  def open_in_file_explorer(path) when is_binary(path) do
    target = Path.expand(path)

    cond do
      not (File.dir?(target) or File.regular?(target)) ->
        {:error, {:path_not_found, target}}

      windows?() ->
        open_windows_explorer(target)

      macos?() ->
        run_open_command("open", [target])

      true ->
        run_open_command("xdg-open", [target])
    end
  end

  defp pick_folder_windows(initial) do
    initial_line =
      case blank_to_nil(initial) do
        nil -> ""
        path -> "$dialog.SelectedPath = '#{escape_ps_single_quoted(path)}';"
      end

    script = """
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select project folder'
    #{initial_line}
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      Write-Output $dialog.SelectedPath
    }
    """

    case System.cmd("powershell.exe", ["-NoProfile", "-STA", "-Command", script],
           stderr_to_stdout: true
         ) do
      {path, 0} ->
        path = path |> String.trim()

        if path == "" do
          {:error, :cancelled}
        else
          {:ok, Path.expand(path)}
        end

      {output, status} ->
        {:error, {:pick_folder_failed, status, output}}
    end
  rescue
    error -> {:error, error}
  end

  defp pick_folder_macos do
    script = ~s/try\nPOSIX path of (choose folder with prompt "Select project folder")\nend try/

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {path, 0} ->
        path = path |> String.trim()

        if path == "" do
          {:error, :cancelled}
        else
          {:ok, Path.expand(path)}
        end

      {_, _} ->
        {:error, :cancelled}
    end
  rescue
    error -> {:error, error}
  end

  defp pick_folder_unix(initial) do
    args =
      case blank_to_nil(initial) do
        nil -> ["--file-selection", "--directory", "--title=Select project folder"]
        path -> ["--file-selection", "--directory", "--title=Select project folder", "--filename=#{path}"]
      end

    case System.find_executable("zenity") do
      nil ->
        {:error, {:command_not_found, "zenity"}}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {path, 0} ->
            path = path |> String.trim()

            if path == "" do
              {:error, :cancelled}
            else
              {:ok, Path.expand(path)}
            end

          {_, _} ->
            {:error, :cancelled}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp escape_ps_single_quoted(value) do
    value |> String.replace("'", "''")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil

  defp open_windows_explorer(target) do
    normalized = String.replace(target, "/", "\\")

    {output, status} =
      System.cmd("explorer.exe", [normalized], stderr_to_stdout: true)

    if status in [0, 1] do
      :ok
    else
      {:error, {:explorer_failed, status, output}}
    end
  rescue
    error -> {:error, error}
  end

  defp run_open_command(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, {:command_not_found, cmd}}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:open_failed, status, output}}
        end
    end
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp macos? do
    case :os.type() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end
end
