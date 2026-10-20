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
  alias Kanban.Workspaces.Policy

  @doc """
  Returns the non-archived, not-completed tasks assigned to the scoped user on
  boards the user is a member of. A task sitting in a Done column is finished
  whatever its status says, so it is left out too.

  Tasks are ordered by board name (then board id, so two boards with
  the same name never interleave), then by priority from `:critical` down to
  `:low`, then by id. `column.board` and `labels` are preloaded, and each
  `column.board.user_access` is set to the user's effective access on that
  board (`:owner`, `:modify` or `:read_only`; derived org-admin access reads as
  `:owner`), from a second query over the distinct boards.

  Returns `[]` for a `nil` scope or a scope without a user.

  ## Options

    * `:limit` - the maximum number of tasks to return (default: no limit)

  """
  @spec list_assigned_tasks(struct() | nil, keyword()) :: [Task.t()]
  def list_assigned_tasks(scope, opts \\ [])
  def list_assigned_tasks(nil, _opts), do: []
  def list_assigned_tasks(%Scope{user: nil}, _opts), do: []

  def list_assigned_tasks(%Scope{user: %{id: user_id} = user} = scope, opts) do
    user_id
    |> open_assigned_tasks()
    |> BoardScope.apply_board_scope_with_column_join(scope)
    |> exclude_done_columns()
    |> join(:inner, [_t, c], b in assoc(c, :board))
    |> order_by_board_then_priority()
    |> preload([_t, c, _scoped, b], column: {c, board: b})
    |> preload(:labels)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
    |> put_user_access(user)
  end

  defp put_user_access(tasks, user) do
    accesses =
      tasks |> Enum.map(& &1.column.board_id) |> Policy.effective_board_accesses(user)

    Enum.map(tasks, &put_in(&1.column.board.user_access, Map.get(accesses, &1.column.board_id)))
  end

  defp open_assigned_tasks(user_id) do
    from(t in Task,
      where: t.assigned_to_id == ^user_id and is_nil(t.archived_at) and t.status != :completed
    )
  end

  # A blocked task keeps its :blocked status when it is moved into a Done column
  # (`Kanban.Tasks.Positioning.determine_status_for_column/2`), so the status
  # filter alone would keep listing it. Only the known name "Done" puts a column
  # in the :done stage (`Kanban.Columns.Stage`), so the name decides here too.
  defp exclude_done_columns(query) do
    where(query, [_t, c], fragment("lower(btrim(?, E' \\t\\n\\r\\f'))", c.name) != "done")
  end

  # Bindings: task, column, accessible board id (from BoardScope), board. Priority is a
  # string column, so it is ranked explicitly rather than sorted alphabetically.
  defp order_by_board_then_priority(query) do
    order_by(query, [t, _c, _scoped, b],
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
