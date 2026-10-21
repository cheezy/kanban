defmodule Kanban.Archives.RetentionTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Archives
  alias Kanban.Tasks.Task

  @day 24 * 60 * 60

  setup do
    board = board_fixture(user_fixture())
    %{board: board, column: column_fixture(board)}
  end

  defp days_ago(days),
    do: DateTime.utc_now(:second) |> DateTime.add(-days * @day, :second)

  defp cutoff, do: days_ago(30)

  defp archive!(%Task{} = task, days_old) do
    from(t in Task, where: t.id == ^task.id)
    |> Repo.update_all(set: [archived_at: days_ago(days_old)])

    task
  end

  defp depends_on!(%Task{} = dependent, %Task{identifier: identifier}) do
    from(t in Task, where: t.id == ^dependent.id)
    |> Repo.update_all(set: [dependencies: [identifier]])

    dependent
  end

  defp exists?(task), do: Repo.get(Task, task.id) != nil

  test "removes only tasks archived strictly before the cutoff", %{column: column} do
    old = column |> task_fixture() |> archive!(31)
    newer = column |> task_fixture() |> archive!(29)
    live = task_fixture(column)

    assert Archives.purge_archived_before(cutoff(), 10) == {1, 1}
    refute exists?(old)
    assert exists?(newer)
    assert exists?(live)
  end

  test "works in batches and reports how many it ran", %{column: column} do
    for _ <- 1..5, do: column |> task_fixture() |> archive!(60)

    assert Archives.purge_archived_before(cutoff(), 2) == {5, 3}
    assert Archives.purge_archived_before(cutoff(), 2) == {0, 1}
  end

  test "never removes a goal while any of its children is not archived", %{column: column} do
    goal = column |> task_fixture(%{type: :goal}) |> archive!(60)
    old_child = column |> task_fixture(%{parent_id: goal.id}) |> archive!(60)
    live_child = task_fixture(column, %{parent_id: goal.id})

    assert {1, _} = Archives.purge_archived_before(cutoff(), 10)
    assert exists?(goal)
    refute exists?(old_child)
    assert exists?(live_child)
  end

  test "keeps a goal whose child was archived after the cutoff", %{column: column} do
    goal = column |> task_fixture(%{type: :goal}) |> archive!(60)
    recent_child = column |> task_fixture(%{parent_id: goal.id}) |> archive!(5)

    assert {0, 1} = Archives.purge_archived_before(cutoff(), 10)
    assert exists?(goal)
    assert exists?(recent_child)
  end

  test "removes an old archived goal together with its old archived children", %{column: column} do
    goal = column |> task_fixture(%{type: :goal}) |> archive!(60)
    children = for _ <- 1..2, do: column |> task_fixture(%{parent_id: goal.id}) |> archive!(45)

    assert {3, _} = Archives.purge_archived_before(cutoff(), 10)
    refute exists?(goal)
    refute Enum.any?(children, &exists?/1)
  end

  test "keeps an archived task that a live task on the same board still depends on",
       %{board: board, column: column} do
    needed = column |> task_fixture() |> archive!(60)
    column |> task_fixture() |> depends_on!(needed)

    other_board_column = column_fixture(board_fixture(user_fixture()))
    unrelated = column |> task_fixture() |> archive!(60)
    other_board_column |> task_fixture() |> depends_on!(unrelated)

    archived_dependent_target = column |> task_fixture() |> archive!(60)
    column |> task_fixture() |> archive!(60) |> depends_on!(archived_dependent_target)

    Archives.purge_archived_before(cutoff(), 10)

    assert exists?(needed)
    refute exists?(unrelated)
    refute exists?(archived_dependent_target)
  end
end
