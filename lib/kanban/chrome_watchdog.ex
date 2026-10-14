defmodule Kanban.ChromeWatchdog do
  @moduledoc """
  Starts ChromicPDF's headless Chrome through `priv/chrome/chrome_watchdog.sh`
  on macOS, so Chrome never outlives the Erlang VM that launched it.

  ## Why this exists

  On macOS, ChromicPDF's Chrome has outlived the VM that started it: it is
  re-parented to launchd (parent PID 1) and keeps running with nothing left
  to close it. 49 of them once piled up on a development machine, from
  `mix test` runs and dev-server restarts, holding about 2.3 GB of memory.
  The test suite's `Kanban.ChromicPDFCleanup` closes Chrome only when the
  suite finishes normally, and nothing closed the dev server's resident
  browser at all.

  `wrap/1` points ChromicPDF's `:chrome_executable` at the watchdog script and
  passes it the real Chrome path and the VM's OS pid. The script runs Chrome
  as its child, with the DevTools pipe unchanged. Once the VM pid is gone, it
  stops Chrome with SIGTERM, then SIGKILL after 2 seconds. That covers every
  way the VM can end, including a SIGKILL or an aborted `mix phx.server`, in
  which no Elixir code runs.

  ## Scope

  Only macOS is wrapped (`{:unix, :darwin}`). Production and CI run Linux,
  where this has not been seen, so their options are returned unchanged.

  The wrapped port's OS pid is the script's, not Chrome's. The script exits
  with Chrome, so a check that the port's OS process has gone still means
  Chrome has gone.
  """

  # ChromicPDF's own default search order (ChromicPDF.ChromeRunner), so wrapping
  # never changes which Chrome runs.
  @default_chromes [
    "chromium-browser",
    "chromium",
    "google-chrome",
    "chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @doc """
  Returns ChromicPDF `opts` that start Chrome through the watchdog script.

  On macOS, `:chrome_executable` becomes the script and `:chrome_args` gains
  the real Chrome path and `vm_pid`. Any other OS, or no Chrome found among
  `opts[:chrome_executable]` and `chromes`, returns `opts` unchanged and
  leaves ChromicPDF to report a missing Chrome itself.
  """
  @spec wrap(keyword(), {atom(), atom()}, String.t(), [String.t()]) :: keyword()
  def wrap(
        opts,
        os_type \\ :os.type(),
        vm_pid \\ System.pid(),
        chromes \\ @default_chromes
      )

  def wrap(opts, {:unix, :darwin}, vm_pid, chromes) do
    case chrome_path(opts, chromes) do
      nil ->
        opts

      chrome ->
        watchdog_args = "--kanban-chrome=#{shell_quote(chrome)} --kanban-watch-pid=#{vm_pid}"

        opts
        |> Keyword.put(:chrome_executable, script_path())
        |> Keyword.update(:chrome_args, watchdog_args, &"#{&1} #{watchdog_args}")
    end
  end

  def wrap(opts, _os_type, _vm_pid, _chromes), do: opts

  @doc "The absolute path of the watchdog script in the app's `priv` directory."
  @spec script_path() :: String.t()
  def script_path, do: Application.app_dir(:kanban, "priv/chrome/chrome_watchdog.sh")

  @doc """
  The Chrome that ChromicPDF would run: `opts[:chrome_executable]` when set,
  else the first of `chromes` found on this machine, else `nil`.
  """
  @spec chrome_path(keyword(), [String.t()]) :: String.t() | nil
  def chrome_path(opts, chromes \\ @default_chromes) do
    Keyword.get_lazy(opts, :chrome_executable, fn ->
      Enum.find_value(chromes, &System.find_executable/1)
    end)
  end

  # ChromicPDF joins :chrome_args into a `sh -c` command line, and the default
  # macOS path has spaces, so quote it for the shell.
  defp shell_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
end
