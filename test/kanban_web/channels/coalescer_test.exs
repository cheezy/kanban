defmodule KanbanWeb.CoalescerTest do
  @moduledoc """
  Tests for `KanbanWeb.Coalescer`, the one-rebuild-per-interval helper the
  app's live channels share (W2766).
  """
  # async: false - one test sets the coalescer's application env.
  use ExUnit.Case, async: false

  alias KanbanWeb.Coalescer

  defp request_times(coalescer, n),
    do: Enum.reduce(1..n, coalescer, fn _, acc -> Coalescer.request(acc) end)

  test "ten messages in a second cause one rebuild" do
    coalescer = [interval: 50] |> Coalescer.new() |> request_times(10)

    assert Coalescer.pending?(coalescer)
    assert_receive :rebuild, 500
    refute_receive :rebuild, 150
  end

  test "a request while one is pending changes nothing" do
    pending = [interval: 50] |> Coalescer.new() |> Coalescer.request()

    assert Coalescer.request(pending) == pending
  end

  test "after fired a new request schedules again" do
    coalescer = Coalescer.new(interval: 10) |> Coalescer.request()
    assert_receive :rebuild, 500

    coalescer = Coalescer.fired(coalescer)
    refute Coalescer.pending?(coalescer)

    coalescer |> Coalescer.request() |> Coalescer.pending?() |> assert()
    assert_receive :rebuild, 500
  end

  test "sends its message to the given process" do
    parent = self()
    Coalescer.new(interval: 10, message: :again) |> Coalescer.request(parent)

    assert_receive :again, 500
  end

  test "the interval is one second unless configured" do
    previous = Application.fetch_env(:kanban, Coalescer)
    Application.delete_env(:kanban, Coalescer)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanban, Coalescer, value)
        :error -> Application.delete_env(:kanban, Coalescer)
      end
    end)

    assert %Coalescer{interval: 1_000, message: :rebuild, timer: nil} = Coalescer.new()

    Application.put_env(:kanban, Coalescer, interval_ms: 25)
    assert Coalescer.new().interval == 25
    assert Coalescer.new(interval: 5).interval == 5
  end
end
