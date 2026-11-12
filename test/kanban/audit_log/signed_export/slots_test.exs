defmodule Kanban.AuditLog.SignedExport.SlotsTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditLog.SignedExport.Slots

  defp start_slots!(opts) do
    start_supervised!({Slots, Keyword.put(opts, :name, nil)}, id: make_ref())
  end

  # Takes a slot in another process and keeps it until told to go.
  defp hold(server) do
    test_pid = self()

    pid =
      spawn(fn ->
        Slots.with_slot(server, fn ->
          send(test_pid, {:holding, self()})
          receive do: (:release -> :ok)
        end)

        send(test_pid, {:released, self()})
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  defp try_slot(server) do
    test_pid = self()
    spawn(fn -> send(test_pid, {:result, self(), Slots.with_slot(server, fn -> :ran end)}) end)
  end

  test "runs the function and returns its result" do
    server = start_slots!(slots: 1, wait: 1000)
    assert Slots.with_slot(server, fn -> :result end) == {:ok, :result}
  end

  test "admits only as many functions at once as there are slots" do
    server = start_slots!(slots: 2, wait: 5000)
    first = hold(server)
    _second = hold(server)

    waiter = try_slot(server)
    refute_receive {:result, ^waiter, _}, 100

    send(first, :release)
    assert_receive {:result, ^waiter, {:ok, :ran}}
  end

  test "a waiter that gets no slot in time gets :busy and the function does not run" do
    server = start_slots!(slots: 1, wait: 50)
    holder = hold(server)

    assert Slots.with_slot(server, fn -> flunk("must not run") end) == {:error, :busy}

    # The slot is still the holder's, and comes free when it is done.
    send(holder, :release)
    assert_receive {:released, ^holder}
    assert Slots.with_slot(server, fn -> :ran end) == {:ok, :ran}
  end

  test "a slot comes back when the function raises" do
    server = start_slots!(slots: 1, wait: 1000)

    assert_raise RuntimeError, fn -> Slots.with_slot(server, fn -> raise "boom" end) end
    assert Slots.with_slot(server, fn -> :ran end) == {:ok, :ran}
  end

  test "a slot comes back when its holder is killed" do
    server = start_slots!(slots: 1, wait: 5000)
    holder = hold(server)

    waiter = try_slot(server)
    refute_receive {:result, ^waiter, _}, 50

    Process.exit(holder, :kill)
    assert_receive {:result, ^waiter, {:ok, :ran}}
  end

  test "a waiter that dies gives up its place in the queue" do
    server = start_slots!(slots: 1, wait: 5000)
    holder = hold(server)

    dead = try_slot(server)
    Process.sleep(50)
    Process.exit(dead, :kill)

    live = try_slot(server)
    refute_receive {:result, ^live, _}, 50

    send(holder, :release)
    assert_receive {:result, ^live, {:ok, :ran}}
    refute_received {:result, ^dead, _}
  end
end
