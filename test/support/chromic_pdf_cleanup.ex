defmodule Kanban.ChromicPDFCleanup do
  @moduledoc """
  Closes ChromicPDF's headless Chrome gracefully in the test suite (D367).

  ## Why this exists

  ChromicPDF talks to Chrome over `--remote-debugging-pipe`. Its graceful
  shutdown sends the DevTools `Browser.close` command from
  `ChromicPDF.Browser.Channel.terminate/2`, but that Channel does not trap
  exits, so when its Browser supervisor stops, the callback never runs. Only
  the pipe is closed, and Chrome on macOS does not exit on pipe EOF. Each
  stopped browser therefore left an orphaned Chrome (parent PID 1). That was
  one per `mix test` run with a resident browser, and one per PDF render in
  on_demand mode.

  This module sends that same `Browser.close` command itself, before the
  browser is torn down. Chrome shuts down through its own DevTools API, and no
  OS signal is ever sent.

  ## Two entry points

    * `attach/0` is called from `test/test_helper.exs`. It adds a `:telemetry`
      handler on the `[:chromic_pdf, :print_to_pdf, :stop | :exception]`
      events. ChromicPDF emits them in the calling process while the on_demand
      per-call browser, which is linked to that process, is still alive. The
      handler closes that browser's Chrome before ChromicPDF stops it.
    * `stop/2` is the `ExUnit.after_suite/1` safety net. It closes any
      resident browser under the ChromicPDF supervisor, then terminates the
      ChromicPDF child.

  ## Limits

    * This reaches into ChromicPDF internals: the Channel and Connection
      process state (`conn_pid`, `next_call_id`, `port`). Every step is
      guarded and degrades to a no-op if those shapes change, so a ChromicPDF
      upgrade can only bring the orphans back, never fail a test. The
      `test/kanban/application_test.exs` OS-process tests detect that
      regression.
    * The browser is closed after every `print_to_pdf`. The app only renders
      single-source PDFs. A multi-source `ChromicPDF.print_to_pdf/2` (join),
      run in on_demand mode, would find its browser closed after the first
      source and fail loudly.
    * Nothing here runs when `mix test` is killed (for example by a hook
      timeout). A Chrome that is mid-render at that moment can still be
      orphaned.

  Every public function returns normally and never raises: the handler runs
  inside the caller's PDF request.
  """

  alias ChromicPDF.Browser.Channel
  alias ChromicPDF.Connection
  alias ChromicPDF.JsonRPC

  @handler_id "kanban-chromic-pdf-cleanup"
  @events [
    [:chromic_pdf, :print_to_pdf, :stop],
    [:chromic_pdf, :print_to_pdf, :exception]
  ]
  @state_timeout 1_000
  @close_timeout 5_000

  @doc """
  Attaches the per-render close handler. Returns `:ok`, or
  `{:error, :already_exists}` if it is already attached.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Detaches the per-render close handler. Returns `:ok`, or
  `{:error, :not_found}` if it was not attached.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  # :telemetry handler. It runs in the process that called print_to_pdf, which
  # is the process the on_demand per-call browser is linked to.
  def handle_event(_event, _measurements, _metadata, _config) do
    self() |> linked_browsers() |> Enum.each(&close_browser/1)
  end

  @doc """
  Closes `supervisor`'s `child_id` ChromicPDF instance and returns `:ok`.

  It first closes any resident browser's Chrome gracefully, then terminates
  the child. It also returns `:ok` when the supervisor is not running, when
  it has no such child, or when the child is already stopped.
  """
  @spec stop(atom() | pid(), term()) :: :ok
  def stop(supervisor \\ Kanban.Supervisor, child_id \\ ChromicPDF) do
    supervisor |> resident_browsers(child_id) |> Enum.each(&close_browser/1)
    terminate(supervisor, child_id)
    :ok
  end

  @doc """
  Asks the Chrome behind a ChromicPDF Browser supervisor to shut down.

  It sends DevTools `Browser.close` over the browser's pipe, then waits up to
  5 seconds for Chrome to close the pipe. Returns `:closed`, `:timeout`, or
  `:skipped` when `browser` is not a live ChromicPDF browser.

  The browser's Connection process is suspended once the command is written.
  The pipe closing is therefore never handled as a crash, which would make
  the Browser supervisor restart and launch a fresh Chrome. The suspended
  process exits with the browser when ChromicPDF stops it.
  """
  @spec close_browser(pid()) :: :closed | :timeout | :skipped
  def close_browser(browser) do
    with {:ok, conn, next_call_id} <- connection(browser),
         {:ok, port} <- port(conn) do
      ref = Port.monitor(port)
      Connection.send_msg(conn, JsonRPC.encode({"Browser.close", %{}}, next_call_id))
      # Handled after the cast above (same sender, so mailbox order), so the
      # command is already on the pipe before the process stops reading.
      :ok = :sys.suspend(conn, @state_timeout)
      await_port_down(ref, port)
    else
      _not_a_browser -> :skipped
    end
  catch
    :exit, _reason -> :skipped
  end

  @doc """
  Returns `{:ok, os_pid}` for the Chrome behind a ChromicPDF Browser
  supervisor, or `:error`. Used by the regression tests to confirm the OS
  process exits.
  """
  @spec chrome_os_pid(pid()) :: {:ok, non_neg_integer()} | :error
  def chrome_os_pid(browser) do
    with {:ok, conn, _next_call_id} <- connection(browser),
         {:ok, port} <- port(conn),
         {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      {:ok, os_pid}
    else
      _ -> :error
    end
  catch
    :exit, _reason -> :error
  end

  @doc """
  Returns the ChromicPDF Browser supervisors linked to `pid`. In on_demand
  mode, that is the per-call browser of a render in progress.
  """
  @spec linked_browsers(pid()) :: [pid()]
  def linked_browsers(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.filter(links, &browser?/1)
      nil -> []
    end
  end

  defp browser?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        dictionary[:"$initial_call"] == {:supervisor, ChromicPDF.Browser, 1}

      nil ->
        false
    end
  end

  defp browser?(_port), do: false

  defp resident_browsers(supervisor, child_id) do
    case find_child(supervisor, &match?({^child_id, pid, _, _} when is_pid(pid), &1)) do
      [{_, chromic_sup, _, _}] -> child_pids(chromic_sup, ChromicPDF.Browser)
      _ -> []
    end
  catch
    :exit, _reason -> []
  end

  defp connection(browser) do
    with [{_, channel, _, _}] <- find_child(browser, &module_child?(&1, Channel)),
         %{conn_pid: conn, next_call_id: next_call_id} when is_pid(conn) <-
           :sys.get_state(channel, @state_timeout) do
      {:ok, conn, next_call_id}
    else
      _ -> :error
    end
  end

  defp port(conn) do
    case :sys.get_state(conn, @state_timeout) do
      %{port: port} when is_port(port) -> {:ok, port}
      _ -> :error
    end
  end

  defp find_child(supervisor, fun) do
    supervisor |> Supervisor.which_children() |> Enum.filter(fun)
  end

  defp child_pids(supervisor, module) do
    supervisor
    |> find_child(&module_child?(&1, module))
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  defp module_child?({_, pid, _, mods}, module), do: is_pid(pid) and module in List.wrap(mods)

  defp await_port_down(ref, port) do
    receive do
      {:DOWN, ^ref, :port, ^port, _reason} -> :closed
    after
      @close_timeout ->
        Port.demonitor(ref, [:flush])
        :timeout
    end
  end

  defp terminate(supervisor, child_id) do
    # :ok or {:error, :not_found} (child already stopped) are both fine.
    Supervisor.terminate_child(supervisor, child_id)
  catch
    # The supervisor is not running (unregistered name or dead pid).
    :exit, _reason -> :ok
  end
end
