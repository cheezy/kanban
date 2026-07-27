defmodule Kanban.Targets.QueriesTest do
  @moduledoc """
  Tests for the batched lead-time sample behind the delivery-target estimate.

  `list_completed_lead_times_by_board/1` replaced the per-target
  `list_completed_lead_times/1` in W1951: one query serves a whole set of
  boards, and the caller re-pools each target from only that target's own
  boards. These tests pin the grouping (the property that makes re-pooling
  possible), the filters, and the no-query empty case.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Targets.Queries

  @day_seconds 86_400

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)

    other_board = board_fixture(user)
    other_column = column_fixture(other_board)

    %{
      board: board,
      column: column,
      other_board: other_board,
      other_column: other_column
    }
  end

  # A completed non-goal task with an EXACT lead time of `days`, both
  # timestamps pinned so assertions never depend on the wall clock.
  # inserted_at is not castable to the past through the changeset, so this
  # bypasses the cast allow-list the same way the targets tests do.
  defp completed_with_lead(column, days) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(
      status: :completed,
      completed_at: ~U[2026-07-01 12:00:00Z],
      inserted_at: NaiveDateTime.add(~N[2026-07-01 12:00:00], -days * @day_seconds)
    )
    |> Repo.update!()
  end

  describe "list_completed_lead_times_by_board/1" do
    test "groups completed non-goal lead times by board id", ctx do
      completed_with_lead(ctx.column, 1)
      completed_with_lead(ctx.other_column, 3)

      sample = Queries.list_completed_lead_times_by_board([ctx.board.id, ctx.other_board.id])

      assert sample == %{
               ctx.board.id => [1.0 * @day_seconds],
               ctx.other_board.id => [3.0 * @day_seconds]
             }
    end

    test "returns the same pooled sample the per-target fetch produced", ctx do
      # The replacement contract: flat-mapping one board's entry back out
      # yields exactly the list the old flat query returned for that board.
      for days <- [1, 2, 4], do: completed_with_lead(ctx.column, days)

      pooled =
        [ctx.board.id]
        |> Queries.list_completed_lead_times_by_board()
        |> Enum.flat_map(fn {_board_id, leads} -> leads end)
        |> Enum.sort()

      assert pooled == [1.0 * @day_seconds, 2.0 * @day_seconds, 4.0 * @day_seconds]
    end

    test "omits a board with no completed non-goal history", ctx do
      # An open task and a completed GOAL are both excluded, so the board has
      # no key at all rather than an empty list.
      task_fixture(ctx.column)
      ctx.column |> task_fixture(%{type: :goal}) |> complete_task()
      completed_with_lead(ctx.other_column, 2)

      sample = Queries.list_completed_lead_times_by_board([ctx.board.id, ctx.other_board.id])

      refute Map.has_key?(sample, ctx.board.id)
      assert sample == %{ctx.other_board.id => [2.0 * @day_seconds]}
    end

    test "ignores boards that were not asked for", ctx do
      completed_with_lead(ctx.column, 1)
      completed_with_lead(ctx.other_column, 3)

      assert Queries.list_completed_lead_times_by_board([ctx.board.id]) ==
               %{ctx.board.id => [1.0 * @day_seconds]}
    end

    test "returns an empty map for an empty board list without querying", ctx do
      completed_with_lead(ctx.column, 1)

      assert Queries.list_completed_lead_times_by_board([]) == %{}
    end
  end

  defp complete_task(task) do
    task
    |> Ecto.Changeset.change(status: :completed, completed_at: ~U[2026-07-01 12:00:00Z])
    |> Repo.update!()
  end
end
