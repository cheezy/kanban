defmodule Kanban.Decisions.ColumnCounts do
  @moduledoc """
  The Ready and Backlog task counts per board that the decision sources read
  (`Kanban.Decisions.Sources`): the `:ready_empty` rule and whether a
  `:move_to_backlog` action would be accepted.

  Columns are recognised as `Kanban.Columns.named?/2` recognises them, case
  and surrounding whitespace ignored, so a board whose column is " READY "
  counts it as Ready.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @agent_task_types [:work, :defect]

  @typedoc "One board's counts; a count is `nil` where the board has no such column."
  @type counts :: %{
          ready: non_neg_integer() | nil,
          backlog: non_neg_integer() | nil,
          backlog_full: boolean()
        }

  @doc """
  Unarchived work and defect tasks in each Ready and Backlog column of
  `board_ids`, as `%{board_id => counts}`. Two columns with the same name on
  one board add up. `backlog_full` is true when a Backlog column is at its
  WIP limit, the rule `Kanban.Tasks.Positioning` refuses a move with. One
  query; none for an empty list. A board with no columns is absent.
  """
  @spec by_board([integer()]) :: %{integer() => counts()}
  def by_board([]), do: %{}

  def by_board(board_ids) when is_list(board_ids) do
    from(c in Column,
      left_join: t in Task,
      on: t.column_id == c.id and is_nil(t.archived_at) and t.type in ^@agent_task_types,
      where: c.board_id in ^board_ids,
      group_by: [c.board_id, c.id, c.name, c.wip_limit],
      select: {c.board_id, c.name, c.wip_limit, count(t.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, &add_column_count/2)
  end

  defp add_column_count({board_id, name, wip_limit, count}, acc) do
    acc
    |> Map.put_new(board_id, %{ready: nil, backlog: nil, backlog_full: false})
    |> Map.update!(board_id, &add_to_counts(&1, column_key(name), wip_limit, count))
  end

  defp add_to_counts(counts, nil, _wip_limit, _count), do: counts

  defp add_to_counts(counts, :backlog, wip_limit, count) do
    %{
      counts
      | backlog: (counts.backlog || 0) + count,
        backlog_full: counts.backlog_full or at_wip_limit?(wip_limit, count)
    }
  end

  defp add_to_counts(counts, key, _wip_limit, count),
    do: Map.update!(counts, key, &((&1 || 0) + count))

  defp at_wip_limit?(wip_limit, count) when is_integer(wip_limit) and wip_limit > 0,
    do: count >= wip_limit

  defp at_wip_limit?(_wip_limit, _count), do: false

  defp column_key(name) do
    cond do
      Columns.named?(%{name: name}, "Ready") -> :ready
      Columns.named?(%{name: name}, "Backlog") -> :backlog
      true -> nil
    end
  end
end
