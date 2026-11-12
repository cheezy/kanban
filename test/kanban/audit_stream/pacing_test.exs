defmodule Kanban.AuditStream.PacingTest do
  @moduledoc """
  The pure parts of `Kanban.AuditStream.Pacing`. What it reads from the
  database, and its settings, are covered through the worker in
  `Kanban.AuditStream.DispatchWorkerTest` and
  `Kanban.AuditStream.DispatchWorkerRaceTest`, the modules that set them.
  """
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.Pacing

  @now ~U[2026-11-12 12:00:00.000000Z]
  @plan %{cursor: %{last_txid: 3}, destination: %{}, audit: nil, follow_up_at: @now}

  test "catching up means a next waiting event strictly more than 10 minutes old" do
    assert Pacing.catch_up_seconds() == 600
    at = DateTime.add(@now, -600, :second)

    refute Pacing.catching_up?(nil, @now)
    refute Pacing.catching_up?(@now, @now)
    refute Pacing.catching_up?(at, @now)
    assert at |> DateTime.add(-1, :microsecond) |> Pacing.catching_up?(@now)
  end

  test "adjust/2 drops the follow-up when caught up or draining" do
    assert Pacing.adjust(@plan, :caught_up) == %{@plan | follow_up_at: nil}
    assert Pacing.adjust(@plan, :drain) == %{@plan | follow_up_at: nil}
    assert Pacing.adjust(@plan, :follow_up) == @plan
  end

  test "adjust/2 sets the follow-up and next_attempt_at 2 seconds ahead when paced" do
    assert Pacing.pace_ms() == 2_000
    at = DateTime.add(@now, Pacing.pace_ms(), :millisecond)

    assert Pacing.adjust(@plan, {:paced, at}) == %{
             @plan
             | follow_up_at: at,
               cursor: %{last_txid: 3, next_attempt_at: at}
           }
  end

  test "continue?/2 only drains an enabled, unhalted destination" do
    assert Pacing.continue?(:drain, %{enabled: true, halted_reason: nil})
    refute Pacing.continue?(:drain, %{enabled: false, halted_reason: nil})
    refute Pacing.continue?(:drain, %{enabled: true, halted_reason: :rejected_batch})
    refute Pacing.continue?(:follow_up, %{enabled: true, halted_reason: nil})
    refute Pacing.continue?(:caught_up, %{enabled: true, halted_reason: nil})
    refute Pacing.continue?({:paced, @now}, %{enabled: true, halted_reason: nil})
  end
end
