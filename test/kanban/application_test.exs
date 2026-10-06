defmodule Kanban.ApplicationTest do
  @moduledoc """
  Regression tests for D367: `mix test` runs leaked an orphaned headless
  Chrome because ChromicPDF started a resident browser at boot. The test
  environment now starts ChromicPDF in on_demand mode (config/test.exs), so a
  Chrome exists only for the duration of a single PDF render, and
  Kanban.ChromicPDFCleanup (attached in test/test_helper.exs) closes that
  Chrome through DevTools after each render. The render tests check the
  Chrome OS process itself (read-only `ps -p`, never a signal), because the
  Erlang-side browser can stop while its Chrome lives on.

  `async: false` because the application env is global and ChromicPDF is a
  shared resource (the same reason the PDF controller tests are async: false).
  """
  use ExUnit.Case, async: false

  alias Kanban.ChromicPDFCleanup

  @flag :chromic_pdf_on_demand

  describe "ChromicPDF wiring under the test config" do
    setup do
      handler_id = "d367-chrome-recorder-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:chromic_pdf, :print_to_pdf, :start],
        &__MODULE__.record_chrome_os_pid/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "starts ChromicPDF without a resident Browser child under the test config" do
      assert Application.get_env(:kanban, @flag) == true

      assert Kanban.Supervisor
             |> Supervisor.which_children()
             |> Enum.any?(fn {id, pid, _, _} -> id == ChromicPDF and is_pid(pid) end)

      children = Supervisor.which_children(ChromicPDF)

      assert browser_children() == []
      # on_demand swaps the resident Browser for an Agent holding the config;
      # the Ghostscript pool is started in both modes.
      assert Enum.any?(children, fn {_, _, _, mods} -> Agent in List.wrap(mods) end)

      assert Enum.any?(children, fn {_, _, _, mods} ->
               ChromicPDF.GhostscriptPool in List.wrap(mods)
             end)
    end

    test "print_to_pdf leaves no Browser child under the ChromicPDF supervisor" do
      links_before = linked_pids()

      assert {:ok, base64} = ChromicPDF.print_to_pdf({:html, "<p>D367</p>"})
      assert "%PDF" <> _ = Base.decode64!(base64)

      assert browser_children() == []
      # The per-call browser is linked to the caller and stopped after the
      # render; it exits asynchronously, so wait for the link to disappear.
      assert_eventually(fn -> linked_pids() -- links_before == [] end)

      # The Chrome OS process that rendered it must be gone too.
      assert_receive {:chrome_os_pid, os_pid}, 5_000
      assert_eventually(fn -> not os_process_alive?(os_pid) end)
    end

    test "concurrent print_to_pdf calls each finish and leave no Browser child" do
      results =
        1..3
        |> Task.async_stream(
          fn n ->
            links_before = linked_pids()
            {:ok, base64} = ChromicPDF.print_to_pdf({:html, "<p>D367 #{n}</p>"})
            assert_eventually(fn -> linked_pids() -- links_before == [] end)
            Base.decode64!(base64)
          end,
          timeout: 60_000,
          max_concurrency: 3
        )
        |> Enum.map(fn {:ok, pdf} -> pdf end)

      assert length(results) == 3
      assert Enum.all?(results, &String.starts_with?(&1, "%PDF"))
      assert browser_children() == []

      # Each render had its own Chrome, and every one of them has exited.
      os_pids =
        for _ <- 1..3 do
          assert_receive {:chrome_os_pid, os_pid}, 5_000
          os_pid
        end

      assert os_pids |> Enum.uniq() |> length() == 3
      assert_eventually(fn -> not Enum.any?(os_pids, &os_process_alive?/1) end)
    end
  end

  describe "chromic_pdf_options/0" do
    setup do
      previous = Application.fetch_env(:kanban, @flag)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kanban, @flag, value)
          :error -> Application.delete_env(:kanban, @flag)
        end
      end)

      :ok
    end

    test "chromic_pdf_options/0 adds on_demand: true only when :chromic_pdf_on_demand is set" do
      Application.put_env(:kanban, @flag, true)
      assert Keyword.get(Kanban.Application.chromic_pdf_options(), :on_demand) == true

      Application.delete_env(:kanban, @flag)
      refute Keyword.has_key?(Kanban.Application.chromic_pdf_options(), :on_demand)

      Application.put_env(:kanban, @flag, false)
      refute Keyword.has_key?(Kanban.Application.chromic_pdf_options(), :on_demand)
    end

    test "chromic_pdf_options/0 keeps no_sandbox, discard_stderr and session_pool timeouts in production mode" do
      Application.delete_env(:kanban, @flag)
      opts = Kanban.Application.chromic_pdf_options()

      assert opts[:no_sandbox] == true
      assert opts[:discard_stderr] == true
      assert opts[:chrome_args] == "--disable-dev-shm-usage --disable-gpu"

      assert opts[:session_pool] == [
               timeout: 30_000,
               init_timeout: 30_000,
               checkout_timeout: 30_000
             ]

      assert opts[:chrome_executable] == System.find_executable("google-chrome-stable")
      refute Keyword.has_key?(opts, :on_demand)
    end
  end

  @doc false
  # :telemetry handler: runs in the rendering process while its on_demand
  # browser is alive, and reports that browser's Chrome OS pid to the test.
  def record_chrome_os_pid(_event, _measurements, _metadata, test_pid) do
    for browser <- ChromicPDFCleanup.linked_browsers(self()),
        {:ok, os_pid} <- [ChromicPDFCleanup.chrome_os_pid(browser)] do
      send(test_pid, {:chrome_os_pid, os_pid})
    end
  end

  # Read-only liveness probe: `ps -p` exits non-zero once the pid is gone.
  defp os_process_alive?(os_pid) do
    {_output, status} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])
    status == 0
  end

  defp browser_children do
    ChromicPDF
    |> Supervisor.which_children()
    |> Enum.filter(fn {_, _, _, mods} -> ChromicPDF.Browser in List.wrap(mods) end)
  end

  defp linked_pids do
    {:links, links} = Process.info(self(), :links)
    Enum.filter(links, &is_pid/1)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      assert_eventually(fun, attempts - 1)
    end
  end
end
