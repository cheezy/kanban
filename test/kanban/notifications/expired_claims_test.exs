defmodule Kanban.Notifications.ExpiredClaimsTest do
  @moduledoc """
  Direct tests of `Kanban.Notifications.ExpiredClaims`;
  `Kanban.Notifications.list_recently_expired_claims/2` delegates here.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Notifications.ExpiredClaims
  alias Kanban.Tasks.Task

  @lookback 2 * 60 * 60

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %{owner: owner, cols: cols, now: now}
  end

  # The changeset rejects claims in the past, so set them with update_all.
  defp claimed_task(ctx, expires_seconds_ago, opts \\ []) do
    {column, opts} = Keyword.pop(opts, :column, "Doing")
    {task_attrs, set} = Keyword.pop(opts, :task_attrs, %{})
    task = task_fixture(ctx.cols[column], Map.merge(%{type: :work}, task_attrs))

    set =
      Keyword.merge(
        [
          status: :in_progress,
          assigned_to_id: ctx.owner.id,
          claim_expires_at: DateTime.add(ctx.now, -expires_seconds_ago, :second)
        ],
        set
      )

    {1, _} = Task |> where([t], t.id == ^task.id) |> Repo.update_all(set: set)
    task
  end

  defp ids(ctx),
    do: ctx.now |> ExpiredClaims.list_recently_expired_claims(@lookback) |> Enum.map(& &1.id)

  test "lists in-window expired claims in Doing, oldest expiry first", ctx do
    newer = claimed_task(ctx, 60)
    older = claimed_task(ctx, 600)
    defect = claimed_task(ctx, 300, task_attrs: %{type: :defect})

    assert ids(ctx) == [older.id, defect.id, newer.id]
  end

  test "the window is half-open: [now - lookback, now)", ctx do
    at_since = claimed_task(ctx, @lookback)
    claimed_task(ctx, @lookback + 1)
    claimed_task(ctx, 0)
    claimed_task(ctx, -60)

    assert ids(ctx) == [at_since.id]
  end

  test "leaves out tasks not being worked in Doing", ctx do
    claimed_task(ctx, 60, column: "Review")
    claimed_task(ctx, 60, column: "Done", status: :completed)
    claimed_task(ctx, 60, status: :open)
    claimed_task(ctx, 60, assigned_to_id: nil)
    claimed_task(ctx, 60, archived_at: ctx.now)
    claimed_task(ctx, 60, human_task: true)

    assert ids(ctx) == []
  end

  test "matches the Doing column whatever its case or padding", ctx do
    task = claimed_task(ctx, 60)
    ctx.cols["Doing"] |> Ecto.Changeset.change(name: "  dOiNg ") |> Repo.update!()

    assert ids(ctx) == [task.id]
  end

  test "refuses a lookback that is not a positive integer", ctx do
    assert_raise FunctionClauseError, fn ->
      ExpiredClaims.list_recently_expired_claims(ctx.now, 0)
    end
  end
end
