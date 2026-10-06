defmodule Kanban.ChromicPDFCleanupTest do
  @moduledoc """
  Pins Kanban.ChromicPDFCleanup, the D367 safety net registered in
  test/test_helper.exs.

  The never-raises tests use their own throwaway supervisor with a stand-in
  child whose id is `ChromicPDF`, so the application's real ChromicPDF
  instance is never stopped mid-suite. The resident-browser test starts its
  own separately named ChromicPDF instance with a real Chrome, and checks
  that Chrome's OS process with a read-only `ps -p` (never a signal).

  `async: false` because the resident-browser test launches a real Chrome,
  which is a shared resource like the PDF controller tests.
  """
  use ExUnit.Case, async: false

  alias Kanban.ChromicPDFCleanup

  defmodule ResidentPDF do
    @moduledoc false
    # A second, separately named ChromicPDF instance (the library's documented
    # multi-instance API), so this test can run a resident browser without
    # touching the application's on_demand instance.
    use ChromicPDF.Supervisor
  end

  defp start_supervisor(children) do
    start_supervised!(%{
      id: make_ref(),
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    })
  end

  defp stand_in_child do
    Supervisor.child_spec({Agent, fn -> :chromic_pdf_stand_in end}, id: ChromicPDF)
  end

  describe "stop/2" do
    test "terminates the ChromicPDF child of the given supervisor" do
      sup = start_supervisor([stand_in_child()])

      assert ChromicPDFCleanup.stop(sup) == :ok
      assert [{ChromicPDF, :undefined, :worker, _}] = Supervisor.which_children(sup)
    end

    test "returns :ok without raising when the ChromicPDF child is already stopped" do
      sup = start_supervisor([stand_in_child()])
      :ok = Supervisor.terminate_child(sup, ChromicPDF)

      # Terminated but still listed: terminate_child/2 is idempotent here.
      assert ChromicPDFCleanup.stop(sup) == :ok

      # Terminated and removed: terminate_child/2 now answers
      # {:error, :not_found}, which stop/2 must still turn into :ok.
      :ok = Supervisor.delete_child(sup, ChromicPDF)
      assert ChromicPDFCleanup.stop(sup) == :ok
    end

    test "returns :ok without raising when the supervisor has no ChromicPDF child" do
      sup = start_supervisor([])

      assert ChromicPDFCleanup.stop(sup) == :ok
    end

    test "returns :ok without raising when the supervisor is not running" do
      assert ChromicPDFCleanup.stop(:"Elixir.Kanban.D367NoSuchSupervisor") == :ok

      {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
      Process.unlink(pid)
      :ok = Supervisor.stop(pid)

      assert ChromicPDFCleanup.stop(pid) == :ok
    end

    test "closes a resident browser's Chrome before terminating the child" do
      opts = Keyword.delete(Kanban.Application.chromic_pdf_options(), :on_demand)
      sup = start_supervisor([{ResidentPDF, opts}])

      [{_, browser, _, _}] =
        ResidentPDF
        |> Supervisor.which_children()
        |> Enum.filter(fn {_, _, _, mods} -> ChromicPDF.Browser in List.wrap(mods) end)

      assert {:ok, os_pid} = ChromicPDFCleanup.chrome_os_pid(browser)
      # Render first: an idle Chrome may exit on pipe EOF alone, but one that
      # has rendered is the one that orphaned.
      assert {:ok, _base64} = ResidentPDF.print_to_pdf({:html, "<p>D367 resident</p>"})
      assert os_process_alive?(os_pid)

      assert ChromicPDFCleanup.stop(sup, ResidentPDF) == :ok

      assert [{ResidentPDF, :undefined, :supervisor, _}] = Supervisor.which_children(sup)
      assert_eventually(fn -> not os_process_alive?(os_pid) end)
    end
  end

  describe "close_browser/1 and chrome_os_pid/1" do
    test "skip a process that is not a ChromicPDF browser" do
      sup = start_supervisor([])

      assert ChromicPDFCleanup.close_browser(sup) == :skipped
      assert ChromicPDFCleanup.chrome_os_pid(sup) == :error
    end

    test "skip a browser that is no longer running" do
      {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
      Process.unlink(pid)
      :ok = Supervisor.stop(pid)

      assert ChromicPDFCleanup.close_browser(pid) == :skipped
      assert ChromicPDFCleanup.chrome_os_pid(pid) == :error
    end
  end

  describe "linked_browsers/1 and handle_event/4" do
    test "find no browser among ordinary links and do nothing" do
      _sup = start_supervisor([])

      assert ChromicPDFCleanup.linked_browsers(self()) == []

      assert ChromicPDFCleanup.handle_event([:chromic_pdf, :print_to_pdf, :stop], %{}, %{}, nil) ==
               :ok
    end

    test "return [] for a process that has exited" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert ChromicPDFCleanup.linked_browsers(pid) == []
    end
  end

  describe "attach/0 and detach/0" do
    test "the handler is attached by test_helper.exs and re-attaching reports it" do
      assert ChromicPDFCleanup.attach() == {:error, :already_exists}

      assert ChromicPDFCleanup.detach() == :ok
      assert ChromicPDFCleanup.detach() == {:error, :not_found}
    after
      ChromicPDFCleanup.attach()
    end
  end

  defp os_process_alive?(os_pid) do
    {_output, status} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])
    status == 0
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
