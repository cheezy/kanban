defmodule Kanban.Decisions.ColumnCounts do
  @moduledoc """
  The Ready and Backlog task counts per board that the decision sources read
  (`Kanban.Decisions.Sources`): the `:ready_empty` rule and whether a
  `:move_to_backlog` action would be accepted.

  A name means one column, as everywhere else in Stride: the board's leftmost
  column of that name, case and surrounding whitespace ignored, so a board
  whose column is " READY " counts it as Ready. The counts are
  `Kanban.Columns.TaskCounts`', the rule `GET /api/me/boards` and the web's
  `/boards` cards count by, so the Now screen agrees with both. A second
  column of the same name is not counted: it is not the column a promote
  fills or a move to Backlog empties into.
  """

  alias Kanban.Columns.TaskCounts

  @typedoc "One board's counts; a count is `nil` where the board has no such column."
  @type counts :: %{
          ready: non_neg_integer() | nil,
          backlog: non_neg_integer() | nil,
          backlog_full: boolean()
        }

  @doc """
  Unarchived work and defect tasks in the leftmost Ready and the leftmost
  Backlog column of each of `board_ids`, as `%{board_id => counts}`.
  `backlog_full` is true when that Backlog column is at its WIP limit, the
  rule `Kanban.Tasks.Positioning` refuses a move with. One query; none for an
  empty list. A board with no columns is absent.
  """
  @spec by_board([integer()]) :: %{integer() => counts()}
  def by_board(board_ids) when is_list(board_ids) do
    board_ids
    |> TaskCounts.by_board()
    |> Map.new(fn {board_id, columns} -> {board_id, counts(columns)} end)
  end

  defp counts(columns) do
    %{
      ready: TaskCounts.count(columns, "Ready"),
      backlog: TaskCounts.count(columns, "Backlog"),
      backlog_full: at_wip_limit?(TaskCounts.column(columns, "Backlog"))
    }
  end

  defp at_wip_limit?(%{wip_limit: wip_limit, count: count})
       when is_integer(wip_limit) and wip_limit > 0,
       do: count >= wip_limit

  defp at_wip_limit?(_backlog), do: false
end
