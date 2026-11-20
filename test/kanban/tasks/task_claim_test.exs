defmodule Kanban.Tasks.TaskClaimTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskClaim

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    %{owner: owner, board: board, cols: cols}
  end

  defp rows(task_id) do
    from(c in TaskClaim, where: c.task_id == ^task_id)
    |> Repo.all()
  end

  describe "record/2" do
    test "stores one row per claim, widening a second-precision time", ctx do
      task = task_fixture(ctx.cols["Ready"])
      at = ~U[2026-11-19 10:00:00Z]

      assert TaskClaim.record(task.id, at) == :ok
      assert TaskClaim.record(task.id, DateTime.add(at, 60)) == :ok

      assert [first, second] = task.id |> rows() |> Enum.sort_by(& &1.claimed_at, DateTime)
      assert first.claimed_at == ~U[2026-11-19 10:00:00.000000Z]
      assert second.claimed_at == ~U[2026-11-19 10:01:00.000000Z]
    end

    test "rows are deleted with their task", ctx do
      task = task_fixture(ctx.cols["Ready"])
      :ok = TaskClaim.record(task.id, DateTime.utc_now())

      Repo.delete!(task)

      assert rows(task.id) == []
    end
  end

  describe "latest_claims/1" do
    test "gives each claimed task its latest claim and leaves unclaimed tasks out", ctx do
      claimed = task_fixture(ctx.cols["Ready"])
      never = task_fixture(ctx.cols["Ready"])
      at = ~U[2026-11-19 10:00:00.000001Z]

      :ok = TaskClaim.record(claimed.id, at)
      :ok = TaskClaim.record(claimed.id, DateTime.add(at, -3600))

      assert TaskClaim.latest_claims([claimed.id, never.id]) == %{claimed.id => at}
    end

    test "runs no query for an empty list" do
      assert TaskClaim.latest_claims([]) == %{}
    end
  end

  describe "claimed_after?/2" do
    test "is true only for a claim strictly after the given time", ctx do
      task = task_fixture(ctx.cols["Ready"])
      at = ~U[2026-11-19 10:00:00.500000Z]
      :ok = TaskClaim.record(task.id, at)

      assert TaskClaim.claimed_after?(task.id, DateTime.add(at, -1, :microsecond))
      refute TaskClaim.claimed_after?(task.id, at)
      refute TaskClaim.claimed_after?(task.id, DateTime.add(at, 1, :second))
    end

    test "accepts a second-precision time", ctx do
      task = task_fixture(ctx.cols["Ready"])
      :ok = TaskClaim.record(task.id, ~U[2026-11-19 10:00:00.500000Z])

      assert TaskClaim.claimed_after?(task.id, ~U[2026-11-19 10:00:00Z])
    end
  end

  describe "the agent claim" do
    test "records a row in its transaction, and an unclaim keeps it", ctx do
      task = task_fixture(ctx.cols["Ready"])
      before = DateTime.utc_now()

      {:ok, claimed, _hook} = Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier)

      assert [row] = rows(task.id)
      assert DateTime.compare(row.claimed_at, before) != :lt

      {:ok, _} = Tasks.unclaim_task(claimed, ctx.owner, nil)

      assert [^row] = rows(task.id)
    end

    test "a refused claim records nothing", ctx do
      task = task_fixture(ctx.cols["Ready"])
      other = user_fixture()

      task
      |> Ecto.Changeset.change(assigned_to_id: other.id)
      |> Repo.update!()

      assert {:error, _} = Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier)
      assert rows(task.id) == []
    end
  end
end
