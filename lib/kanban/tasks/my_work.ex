defmodule Kanban.Tasks.MyWork do
  @moduledoc """
  The cross-board "My Work" queue (W2237): every open task assigned to the
  current user on a board they still belong to.

  Board access is enforced in exactly one place, `Kanban.Queries.BoardScope`,
  so a stale assignment on a board the user has since been removed from — or
  an assignment on a public board they never joined — is never listed.

  `BoardScope` returns its query *unfiltered* for a `nil` scope or a scope
  without a user, so `list_assigned_tasks/2` refuses those scopes outright
  rather than relying on the assignee filter alone.

  Tasks have no due dates (scheduling comes from delivery targets), so the
  queue is ordered by board and then by priority, never by date.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Returns the non-archived, not-completed tasks assigned to the scoped user on
  boards the user is a member of.

  One query: tasks are ordered by board name (then board id, so two boards with
  the same name never interleave), then by priority from `:critical` down to
  `:low`, then by id. `column.board` and `labels` are preloaded, and each
  `column.board.user_access` is set to the user's membership access on that
  board (`:owner`, `:modify` or `:read_only`).

  Returns `[]` for a `nil` scope or a scope without a user.

  ## Options

    * `:limit` - the maximum number of tasks to return (default: no limit)

  """
  @spec list_assigned_tasks(struct() | nil, keyword()) :: [Task.t()]
  def list_assigned_tasks(scope, opts \\ [])
  def list_assigned_tasks(nil, _opts), do: []
  def list_assigned_tasks(%Scope{user: nil}, _opts), do: []

  def list_assigned_tasks(%Scope{user: %{id: user_id}} = scope, opts) do
    user_id
    |> open_assigned_tasks()
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> join(:inner, [_t, c], b in assoc(c, :board))
    |> order_by_board_then_priority()
    |> preload([_t, c, _bu, b], column: {c, board: b})
    |> preload(:labels)
    |> select([t, _c, bu, _b], {t, bu.access})
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
    |> Enum.map(&put_user_access/1)
  end

  defp open_assigned_tasks(user_id) do
    from(t in Task,
      where: t.assigned_to_id == ^user_id and is_nil(t.archived_at) and t.status != :completed
    )
  end

  # Bindings: task, column, board_user (from BoardScope), board. Priority is a
  # string column, so it is ranked explicitly rather than sorted alphabetically.
  defp order_by_board_then_priority(query) do
    order_by(query, [t, _c, _bu, b],
      asc: b.name,
      asc: b.id,
      asc:
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END",
          t.priority
        ),
      asc: t.id
    )
  end

  # The membership row the scope join already matched carries the user's access
  # level on that board; record it on the board's virtual `user_access` field so
  # callers can tell a read-only membership apart without another query.
  defp put_user_access({task, access}), do: put_in(task.column.board.user_access, access)

  @doc """
  Groups tasks returned by `list_assigned_tasks/2` into `{board, tasks}`
  tuples, preserving the query's board and priority order.

  Expects each task to carry a preloaded `column.board`.
  """
  @spec group_by_board([Task.t()]) :: [{struct(), [Task.t()]}]
  def group_by_board(tasks) do
    tasks
    |> Enum.chunk_by(& &1.column.board.id)
    |> Enum.map(fn [first | _] = chunk -> {first.column.board, chunk} end)
  end

  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0,
    do: limit(query, ^limit)

  defp maybe_limit(query, _limit), do: query
end
