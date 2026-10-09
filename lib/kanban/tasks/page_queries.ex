defmodule Kanban.Tasks.PageQueries do
  @moduledoc """
  Board-scoped, keyset-paginated task listing for `GET /api/tasks` (W2224).

  Split out of `Kanban.Tasks.Queries`, which was already past the module-size
  guideline; that module delegates `list_board_tasks_page/3` here.

  **Board scoping is the first constraint of every query.** Tasks carry no
  `board_id`, so the board is reached through the task's column. The cursor is
  only ever used as `t.id > ^cursor` inside that already board-scoped query,
  and a `parent` goal identifier is resolved by a subquery scoped to the same
  board — so neither a crafted cursor nor another board's goal identifier can
  surface another board's tasks, and an unknown or non-goal identifier yields
  an empty page rather than an existence oracle.

  **Keyset, not offset.** Pages are ordered by `id` ascending and continue from
  the last id seen, so tasks created between page fetches land on later pages
  instead of shifting rows and causing skips or repeats.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.BoardFilters
  alias Kanban.Tasks.Task

  @doc """
  Returns one page of the board's non-archived tasks and the id to continue
  from.

  `filters` is a map whose keys may be `:column_id`, `:status`, `:type`,
  `:priority`, `:assigned_to_id`, `:parent` (a goal identifier),
  `:updated_since` (a `NaiveDateTime`, inclusive) and `:label_id` (matched as
  `Kanban.Tasks.BoardFilters` matches it, so a goal with a matching child is
  included); all present filters are ANDed. `opts` requires `:limit` and accepts `:after_id` (the decoded cursor).

  Returns `{tasks, next_id}` where `next_id` is the id of the last task on this
  page when a further page exists, and `nil` when this is the last page.
  """
  @spec list_board_tasks_page(integer(), map(), keyword()) :: {[Task.t()], pos_integer() | nil}
  def list_board_tasks_page(board_id, filters, opts) do
    limit = Keyword.fetch!(opts, :limit)

    query =
      from(t in Task,
        join: c in Column,
        on: c.id == t.column_id,
        where: c.board_id == ^board_id and is_nil(t.archived_at)
      )
      |> after_id(Keyword.get(opts, :after_id))

    filters
    |> Enum.reduce(query, fn filter, acc -> apply_filter(acc, filter, board_id) end)
    |> order_by([t], asc: t.id)
    |> limit(^(limit + 1))
    |> preload([:assigned_to, :labels])
    |> Repo.all()
    |> split_page(limit)
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [t], t.id > ^id)

  defp apply_filter(query, {:column_id, id}, _board_id),
    do: where(query, [t], t.column_id == ^id)

  defp apply_filter(query, {:status, status}, _board_id),
    do: where(query, [t], t.status == ^status)

  defp apply_filter(query, {:type, type}, _board_id),
    do: where(query, [t], t.type == ^type)

  defp apply_filter(query, {:priority, priority}, _board_id),
    do: where(query, [t], t.priority == ^priority)

  defp apply_filter(query, {:assigned_to_id, user_id}, _board_id),
    do: where(query, [t], t.assigned_to_id == ^user_id)

  defp apply_filter(query, {:updated_since, since}, _board_id),
    do: where(query, [t], t.updated_at >= ^since)

  # W2239: the board filter bar's own label rule, so API and board results
  # agree — including a goal shown for a matching child. The base query is
  # already board-scoped, and the label must be on the task's own board.
  defp apply_filter(query, {:label_id, id}, _board_id),
    do: BoardFilters.apply_filters(query, %BoardFilters{label_id: id})

  defp apply_filter(query, {:parent, identifier}, board_id) do
    goal_ids =
      from(g in Task,
        join: gc in Column,
        on: gc.id == g.column_id,
        where: gc.board_id == ^board_id and g.identifier == ^identifier and g.type == :goal,
        select: g.id
      )

    where(query, [t], t.parent_id in subquery(goal_ids))
  end

  defp split_page(rows, limit) do
    case Enum.split(rows, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, List.last(page).id}
    end
  end
end
