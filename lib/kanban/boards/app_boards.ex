defmodule Kanban.Boards.AppBoards do
  @moduledoc """
  The board list of the app's Boards tab (`GET /api/me/boards`, W2759,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.9, §7.10). Called as
  `Kanban.Boards.list_boards_for_app/2`.

  The boards are the ones `/boards` shows, in its order
  (`Kanban.Boards.list_boards/1`), less any board the plan does not unlock
  (`Kanban.Plans.unlocked_board_ids/1`), as the app's other cross-board lists
  leave them out (design §7.10, "Plans on cross-board lists"). For each board
  it adds:

    * `counts` — the live work and defect tasks in the board's Backlog,
      Ready, Doing, Review and Done columns: the tasks the column read
      (`Kanban.Tasks.list_column_page/3`) serves for that name, so a count
      equals the column read's `total`. A name resolves to one column as the
      rest of the app resolves it (`Kanban.Columns.get_column_by_name/2`):
      the board's lowest-positioned column of that name, case and
      surrounding whitespace ignored. A second column of the same name is not
      counted, and a column the board does not have counts 0;
    * `idle_agents` — agents that worked on the board in the last 24 hours
      and are idle now (`Kanban.Agents.Idle`, the `:ready_empty` rule);
    * `group` and `workspace` — `:workspace` with the workspace when it is a
      workspace of the person's Organization, `:personal` with their personal
      workspace, else `:shared` with no workspace, so a board shared from
      someone else's workspace never names it.

  Every query here is scoped to the boards the person can already see.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.Agents.Idle
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @counted_columns [
    backlog: "Backlog",
    ready: "Ready",
    doing: "Doing",
    review: "Review",
    done: "Done"
  ]

  @type entry :: %{
          board: Board.t(),
          access: :owner | :modify | :read_only,
          group: :workspace | :personal | :shared,
          workspace: Workspace.t() | nil,
          counts: %{
            backlog: non_neg_integer(),
            ready: non_neg_integer(),
            doing: non_neg_integer(),
            review: non_neg_integer(),
            done: non_neg_integer()
          },
          idle_agents: non_neg_integer()
        }

  @doc """
  The person's boards for the app, as a list of `t:entry/0` in `/boards`
  order. Options: `:now` (default `DateTime.utc_now/0`) anchors the
  idle-agent window.
  """
  @spec list(Scope.t(), keyword()) :: [entry()]
  def list(%Scope{user: user} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case unlocked(Boards.list_boards(user)) do
      [] -> []
      boards -> entries(boards, scope, now)
    end
  end

  defp unlocked(boards) do
    unlocked = boards |> Enum.map(& &1.id) |> Plans.unlocked_board_ids()
    Enum.filter(boards, &MapSet.member?(unlocked, &1.id))
  end

  defp entries(boards, scope, now) do
    ids = Enum.map(boards, & &1.id)
    column_counts = column_counts(ids)
    idle = Idle.count_by_board(scope, ids, now)
    workspaces = visible_workspaces(scope)

    Enum.map(boards, fn board ->
      {group, workspace} = group(board, workspaces)

      %{
        board: board,
        access: board.user_access,
        group: group,
        workspace: workspace,
        counts: counts(Map.get(column_counts, board.id, [])),
        idle_agents: Map.get(idle, board.id, 0)
      }
    end)
  end

  # Every column of `board_ids` with its live work and defect task count, the
  # cards Kanban.Tasks.list_column_page/3 pages, as %{board_id => [{name,
  # count}]} with each board's columns by position. One query.
  defp column_counts(board_ids) do
    from(c in Column,
      left_join: t in Task,
      on: t.column_id == c.id and is_nil(t.archived_at) and t.type in [:work, :defect],
      where: c.board_id in ^board_ids,
      group_by: c.id,
      order_by: [c.board_id, c.position, c.id],
      select: {c.board_id, c.name, count(t.id)}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_board_id, name, count} -> {name, count} end)
  end

  defp counts(columns),
    do: Map.new(@counted_columns, fn {key, name} -> {key, count_of(columns, name)} end)

  # The count of the board's first column, by position, with `name`: the
  # column Kanban.Columns.get_column_by_name/2 resolves the name to.
  defp count_of(columns, name) do
    case Enum.find(columns, fn {column_name, _count} -> named?(column_name, name) end) do
      {_column_name, count} -> count
      nil -> 0
    end
  end

  defp named?(column_name, name), do: Columns.named?(%{name: column_name}, name)

  # The person's Organization workspaces and their personal workspace.
  defp visible_workspaces(%Scope{user: user} = scope) do
    {_membership, org_workspaces} =
      Workspaces.list_workspaces_with_membership(user, scope.organization_membership)

    %{
      org: Map.new(org_workspaces, &{&1.id, &1}),
      personal: Workspaces.get_personal_workspace(user)
    }
  end

  defp group(%Board{workspace_id: nil}, _workspaces), do: {:shared, nil}

  defp group(%Board{workspace_id: id}, %{org: org, personal: personal}) do
    case {Map.get(org, id), personal} do
      {%Workspace{} = workspace, _personal} -> {:workspace, workspace}
      {nil, %Workspace{id: ^id} = workspace} -> {:personal, workspace}
      _shared -> {:shared, nil}
    end
  end
end
