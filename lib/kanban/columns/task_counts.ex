defmodule Kanban.Columns.TaskCounts do
  @moduledoc """
  The live work and defect task count of every column of some boards, and the
  one rule for reading a count by column name. The app's board list
  (`Kanban.Boards.AppBoards`, `GET /api/me/boards`), the web's `/boards`
  cards and board header (`Kanban.Boards.Metrics`) and the Now screen's
  decision sources (`Kanban.Decisions.ColumnCounts`) all count through it, so
  the web and the app never disagree.

  A name means one column, as everywhere else in Stride (a claim, a promote,
  a completion, a review, the web's Backlog arrow): the board's leftmost
  column of that name, case and surrounding whitespace ignored
  (`Kanban.Columns.first_named/2`, the column
  `Kanban.Columns.get_column_by_name/2` returns). On a board with two columns
  of one name only the leftmost is counted, and a name the board has no
  column for has no count (`nil`).

  A counted task is unarchived and a work or defect task, the cards
  `Kanban.Tasks.list_column_page/3` pages, so a count equals that column
  read's `total`. Goals are never counted.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @counted_types [:work, :defect]

  @typedoc "One column of a board with its live work and defect task count."
  @type column_count :: %{
          id: integer(),
          name: String.t(),
          wip_limit: integer() | nil,
          count: non_neg_integer()
        }

  @doc """
  Every column of `board_ids` with its count, as `%{board_id =>
  [column_count]}`, each board's columns in position order (then id), empty
  columns included so the leftmost of a name is always known. A board with no
  columns has no key. One query; `[]` makes none.
  """
  @spec by_board([integer()]) :: %{integer() => [column_count()]}
  def by_board([]), do: %{}

  def by_board(board_ids) when is_list(board_ids) do
    from(c in Column,
      left_join: t in Task,
      on: t.column_id == c.id and is_nil(t.archived_at) and t.type in ^@counted_types,
      where: c.board_id in ^board_ids,
      group_by: c.id,
      order_by: [c.board_id, c.position, c.id],
      select: {c.board_id, %{id: c.id, name: c.name, wip_limit: c.wip_limit, count: count(t.id)}}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The leftmost of one board's `columns` (as `by_board/1` lists them) named
  `name`, or `nil` when the board has none.
  """
  @spec column([column_count()], String.t()) :: column_count() | nil
  def column(columns, name), do: Columns.first_named(columns, name)

  @doc """
  The count of the leftmost of `columns` named `name`, or `nil` when the
  board has no column of that name. A second column of the same name is not
  counted.
  """
  @spec count([column_count()], String.t()) :: non_neg_integer() | nil
  def count(columns, name) do
    case column(columns, name) do
      %{count: count} -> count
      nil -> nil
    end
  end
end
