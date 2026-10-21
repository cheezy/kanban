defmodule Kanban.Tasks.ClaimReleaseTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Tasks.ClaimRelease
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    agent = user_fixture()
    board = ai_optimized_board_fixture(owner)
    %{owner: owner, agent: agent, board: board}
  end

  defp column(board, name), do: board |> Columns.list_columns() |> Enum.find(&(&1.name == name))

  # A task in `column_name` held by `user` through a claim, set directly.
  defp claimed_task(board, user, column_name \\ "Doing", extra \\ []) do
    task = task_fixture(column(board, column_name))
    now = DateTime.utc_now(:second)

    fields =
      [
        status: :in_progress,
        claimed_at: now,
        claim_expires_at: DateTime.add(now, 3600),
        assigned_to_id: user.id
      ] ++ extra

    task |> Ecto.Changeset.change(fields) |> Repo.update!()
  end

  test "returns a claimed task to the end of Ready, open, unclaimed and unassigned", ctx do
    ready = column(ctx.board, "Ready")
    waiting = task_fixture(ready)
    task = claimed_task(ctx.board, ctx.agent)

    assert [%Task{id: id}] = ClaimRelease.release(ctx.agent.id, [ctx.board.id])
    assert id == task.id

    released = Repo.get!(Task, task.id)
    assert released.status == :open
    assert released.column_id == ready.id
    assert released.position > Repo.get!(Task, waiting.id).position
    assert is_nil(released.claimed_at)
    assert is_nil(released.claim_expires_at)
    assert is_nil(released.assigned_to_id)
  end

  test "leaves tasks that are not the user's live claims alone", ctx do
    other = user_fixture()
    theirs = claimed_task(ctx.board, other)

    completed =
      claimed_task(ctx.board, ctx.agent, "Review", completed_at: DateTime.utc_now(:second))

    archived = claimed_task(ctx.board, ctx.agent, "Doing", archived_at: DateTime.utc_now(:second))

    assigned_only =
      ctx.board
      |> column("Backlog")
      |> task_fixture()
      |> Ecto.Changeset.change(assigned_to_id: ctx.agent.id)
      |> Repo.update!()

    assert ClaimRelease.release(ctx.agent.id, :all) == []

    for task <- [theirs, completed, archived, assigned_only] do
      assert Repo.get!(Task, task.id) == task
    end
  end

  test "only releases claims on the boards named, by id list or by query", ctx do
    elsewhere = ai_optimized_board_fixture(ctx.owner)
    here = claimed_task(ctx.board, ctx.agent)
    there = claimed_task(elsewhere, ctx.agent)

    assert ClaimRelease.release(ctx.agent.id, []) == []
    assert [%Task{id: id}] = ClaimRelease.release(ctx.agent.id, [elsewhere.id])
    assert id == there.id
    assert Repo.get!(Task, here.id).status == :in_progress

    query = from(b in Kanban.Boards.Board, where: b.id == ^ctx.board.id, select: b.id)
    here_id = here.id
    assert [%Task{id: ^here_id}] = ClaimRelease.release(ctx.agent.id, query)
  end

  test "leaves a claimed task on a board without a Ready column where it is", ctx do
    board = board_fixture(ctx.owner)
    doing = column_fixture(board, %{name: "Doing"})

    task =
      doing
      |> task_fixture()
      |> Ecto.Changeset.change(
        status: :in_progress,
        claimed_at: DateTime.utc_now(:second),
        assigned_to_id: ctx.agent.id
      )
      |> Repo.update!()

    assert ClaimRelease.release(ctx.agent.id, :all) == []
    assert Repo.get!(Task, task.id).column_id == doing.id
  end
end
