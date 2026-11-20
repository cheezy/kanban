defmodule Kanban.Boards.AppBoardsTest do
  # async: false - one test switches the global :plans_enforced application env on.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user), board: ai_optimized_board_fixture(user)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp entry(entries, board), do: Enum.find(entries, &(&1.board.id == board.id))

  # Runs `fun` and counts the Repo queries this process issued meanwhile.
  defp count_queries(fun) do
    test_pid = self()
    ref = :counters.new(1, [])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(ref, 1, 1)
      end,
      nil
    )

    try do
      {fun.(), :counters.get(ref, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "lists the boards of /boards, in its order, with access and column counts", ctx do
    cols = columns(ctx.board)
    for _ <- 1..2, do: task_fixture(cols["Backlog"])
    task_fixture(cols["Backlog"], %{type: :goal})
    task_fixture(cols["Ready"])
    task_fixture(cols["Doing"])
    task_fixture(cols["Done"])

    second = board_fixture(ctx.user)
    entries = Boards.list_boards_for_app(ctx.scope)

    assert Enum.map(entries, & &1.board.id) ==
             ctx.user |> Boards.list_boards() |> Enum.map(& &1.id)

    assert %{access: :owner, counts: counts, idle_agents: 0} = entry(entries, ctx.board)
    assert counts == %{backlog: 2, ready: 1, doing: 1, review: 0, done: 1}

    # A board without the standard columns counts 0 for each.
    assert entry(entries, second).counts == %{backlog: 0, ready: 0, doing: 0, review: 0, done: 0}
  end

  test "groups boards by workspace without naming someone else's", ctx do
    personal = Kanban.Workspaces.get_personal_workspace(ctx.user)

    organization = organization_fixture()
    organization_member_fixture(organization, ctx.user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, ctx.user)
    org_board = board_fixture(ctx.user)
    org_board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Kanban.Repo.update!()

    owner = user_fixture()
    shared = board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(shared, ctx.user, :read_only, owner)

    entries = Boards.list_boards_for_app(ctx.scope)

    assert %{group: :personal, workspace: %{id: personal_id}} = entry(entries, ctx.board)
    assert personal_id == personal.id
    assert %{group: :workspace, workspace: %{id: workspace_id}} = entry(entries, org_board)
    assert workspace_id == workspace.id
    assert %{group: :shared, workspace: nil, access: :read_only} = entry(entries, shared)
  end

  test "counts idle agents that worked on the board in the last 24 hours", ctx do
    cols = columns(ctx.board)

    {:ok, _} =
      cols["Done"]
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: "Claude",
        completed_by_agent: "Claude",
        completed_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second),
        status: :completed
      })

    assert [%{idle_agents: 1}] = Boards.list_boards_for_app(ctx.scope)
  end

  test "leaves out boards the plan does not unlock", ctx do
    enforce_plans()
    assert Boards.list_boards_for_app(ctx.scope) == []
  end

  test "a person with no boards gets an empty list" do
    user = user_fixture()
    scope = Scope.for_user(user)

    {[], board_reads} = count_queries(fn -> Boards.list_boards(user) end)
    {_unlocked, plan_reads} = count_queries(fn -> Kanban.Plans.unlocked_board_ids([]) end)

    # Nothing but the board list and its plan filter is read: no counts, no
    # idle agents and no workspaces.
    assert {[], reads} = count_queries(fn -> Boards.list_boards_for_app(scope) end)
    assert reads == board_reads + plan_reads
  end

  test "a column named in another case still counts", ctx do
    other = board_fixture(ctx.user)
    backlog = column_fixture(other, %{name: " backlog "})
    task_fixture(backlog)

    assert entry(Boards.list_boards_for_app(ctx.scope), other).counts.backlog == 1
  end

  test "two columns of one name count only the leftmost, the one the column read serves", ctx do
    other = board_fixture(ctx.user)
    # Created first, so the lower id, but moved right of its namesake below.
    right_backlog = column_fixture(other, %{name: "Backlog"})
    right_done = column_fixture(other, %{name: "Done"})
    left_backlog = column_fixture(other, %{name: " backlog "})
    left_done = column_fixture(other, %{name: "DONE"})

    :ok =
      Columns.reorder_columns(
        other,
        [left_backlog.id, left_done.id, right_backlog.id, right_done.id],
        ctx.user
      )

    for _ <- 1..2, do: task_fixture(left_backlog)
    for _ <- 1..3, do: task_fixture(right_backlog)
    task_fixture(left_done)
    for _ <- 1..4, do: task_fixture(right_done)

    assert %{backlog: 2, done: 1} = entry(Boards.list_boards_for_app(ctx.scope), other).counts

    # The column read resolves each name to the same column and agrees.
    for {name, count} <- [{"Backlog", 2}, {"Done", 1}] do
      column = Columns.get_column_by_name(other.id, name)
      assert column.id in [left_backlog.id, left_done.id]
      assert {:ok, %{total: ^count}} = Tasks.list_column_page(ctx.scope, column)
    end
  end
end
