defmodule Kanban.Decisions.HoldsUpTest do
  @moduledoc """
  Tests for `Kanban.Decisions.HoldsUp.held/1`.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Decisions.HoldsUp

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    %{owner: owner, board: board, column: backlog(board)}
  end

  defp backlog(board) do
    board |> Columns.list_columns() |> Enum.find(&(&1.name == "Backlog"))
  end

  # Sets dependencies directly: task_fixture/2 swaps given dependencies for
  # new placeholder tasks, and the changeset would refuse a cycle.
  defp dependent!(column, identifiers) do
    column
    |> task_fixture()
    |> Ecto.Changeset.change(dependencies: identifiers)
    |> Repo.update!()
  end

  # A chain of n tasks, each depending on the one before, starting at root.
  defp chain!(column, root, n) do
    {tasks, _last} =
      Enum.map_reduce(1..n, root, fn _i, previous ->
        task = dependent!(column, [previous.identifier])
        {task, task}
      end)

    tasks
  end

  defp held(board, root) do
    %{board.id => [root.identifier]}
    |> HoldsUp.held()
    |> Map.fetch!(:roots)
    |> Map.get({board.id, root.identifier}, [])
  end

  defp identifiers(tasks), do: Enum.map(tasks, & &1.identifier)

  defp count_queries(fun) do
    test_pid = self()
    handler_id = "w2757-query-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, :repo_query)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries(0)
  end

  defp drain_queries(count) do
    receive do
      :repo_query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end

  test "counts direct and chained dependents", ctx do
    root = task_fixture(ctx.column)
    a = dependent!(ctx.column, [root.identifier])
    b = dependent!(ctx.column, [root.identifier, "W99999"])
    c = dependent!(ctx.column, [a.identifier])
    d = dependent!(ctx.column, [c.identifier])

    # Nearest first, then oldest.
    assert held(ctx.board, root) == identifiers([a, b, c, d])
  end

  test "stops at depth 5 and caps at 50", ctx do
    root = task_fixture(ctx.column)
    chain = chain!(ctx.column, root, 6)

    assert held(ctx.board, root) == chain |> Enum.take(5) |> identifiers()

    wide = task_fixture(ctx.column)
    dependents = for _i <- 1..51, do: dependent!(ctx.column, [wide.identifier])

    assert held(ctx.board, wide) == dependents |> Enum.take(50) |> identifiers()
    assert HoldsUp.cap() == 50
    assert HoldsUp.max_depth() == 5
  end

  test "exactly 5 levels and 50 dependents are all counted", ctx do
    root = task_fixture(ctx.column)
    chain = chain!(ctx.column, root, 5)
    assert held(ctx.board, root) == identifiers(chain)

    wide = task_fixture(ctx.column)
    dependents = for _i <- 1..50, do: dependent!(ctx.column, [wide.identifier])
    assert held(ctx.board, wide) == identifiers(dependents)
  end

  test "ignores done and archived dependents", ctx do
    root = task_fixture(ctx.column)

    done =
      ctx.column
      |> dependent!([root.identifier])
      |> Ecto.Changeset.change(status: :completed)
      |> Repo.update!()

    ctx.column
    |> dependent!([root.identifier])
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    # Waits only on the finished task, so the chain stops there.
    dependent!(ctx.column, [done.identifier])

    assert held(ctx.board, root) == []
  end

  test "a dependency cycle terminates", ctx do
    root = task_fixture(ctx.column)
    a = dependent!(ctx.column, [root.identifier])
    b = dependent!(ctx.column, [a.identifier])

    a |> Ecto.Changeset.change(dependencies: [root.identifier, b.identifier]) |> Repo.update!()

    root
    |> Ecto.Changeset.change(dependencies: [b.identifier])
    |> Repo.update!()

    assert held(ctx.board, root) == identifiers([a, b])
  end

  test "a task with no dependents holds up 0", ctx do
    root = task_fixture(ctx.column)

    empty = %{roots: %{}, boards: %{}}
    assert HoldsUp.held(%{ctx.board.id => [root.identifier]}) == empty
    assert held(ctx.board, root) == []
    assert HoldsUp.held(%{}) == empty
  end

  test "runs one query per board", ctx do
    root = task_fixture(ctx.column)
    chain!(ctx.column, root, 3)
    other_root = task_fixture(ctx.column)

    second = ai_optimized_board_fixture(ctx.owner)
    second_root = task_fixture(backlog(second))
    chain!(backlog(second), second_root, 3)

    roots = %{
      ctx.board.id => [root.identifier, other_root.identifier, root.identifier],
      second.id => [second_root.identifier]
    }

    assert count_queries(fn -> HoldsUp.held(roots) end) == 2
    assert count_queries(fn -> HoldsUp.held(%{}) end) == 0
    assert count_queries(fn -> HoldsUp.held(%{ctx.board.id => []}) end) == 0
  end

  test "dependents on another board are not counted", ctx do
    root = task_fixture(ctx.column)
    task_fixture(ctx.column)
    other_column = ctx.owner |> ai_optimized_board_fixture() |> backlog()

    # The other board has its own task with the root's identifier, and a task
    # that depends on that identifier: neither belongs to the root's chain.
    twin = task_fixture(other_column)
    stranger = dependent!(other_column, [root.identifier])
    mine = dependent!(ctx.column, [root.identifier])

    assert twin.identifier == root.identifier
    refute stranger.identifier in [root.identifier, mine.identifier]
    assert held(ctx.board, root) == [mine.identifier]
  end

  test "two roots holding up the same task both count it", ctx do
    first = task_fixture(ctx.column)
    second = task_fixture(ctx.column)
    shared = dependent!(ctx.column, [first.identifier, second.identifier])

    held = HoldsUp.held(%{ctx.board.id => [first.identifier, second.identifier]})

    assert held == %{
             roots: %{
               {ctx.board.id, first.identifier} => [shared.identifier],
               {ctx.board.id, second.identifier} => [shared.identifier]
             },
             boards: %{ctx.board.id => [shared.identifier]}
           }
  end

  test "board totals list every distinct held task, past the per-root cap", ctx do
    wide = task_fixture(ctx.column)
    narrow = task_fixture(ctx.column)
    dependents = for _i <- 1..55, do: dependent!(ctx.column, [wide.identifier])

    # The narrow root shares the first ten, which the wide root's cap keeps.
    for task <- Enum.take(dependents, 10) do
      task
      |> Ecto.Changeset.change(dependencies: [wide.identifier, narrow.identifier])
      |> Repo.update!()
    end

    %{roots: roots, boards: boards} =
      HoldsUp.held(%{ctx.board.id => [wide.identifier, narrow.identifier]})

    assert length(roots[{ctx.board.id, wide.identifier}]) == 50
    assert length(roots[{ctx.board.id, narrow.identifier}]) == 10
    assert Enum.sort(boards[ctx.board.id]) == dependents |> identifiers() |> Enum.sort()
  end
end
