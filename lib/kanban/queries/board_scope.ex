defmodule Kanban.Queries.BoardScope do
  @moduledoc """
  Shared board-membership scoping for task queries — the data-access
  boundary that keeps users from seeing tasks on boards they do not
  belong to.

  Extracted from the private `apply_scope/2` copies that previously lived
  in `Kanban.Agents`, `Kanban.Archives`, and `Kanban.Reviews` (W1083).
  Two variants exist because the base queries come in two shapes, and the
  generated queries must stay equivalent to the originals:

    * `apply_board_scope/2` — for queries that already join the task's
      column under the named binding `:column` (archives, reviews).
    * `apply_board_scope_with_column_join/2` — for bare task queries with
      no column join yet; adds the column join itself (agents).

  Both return the query unchanged for a `nil` scope or a scope without a
  user, mirroring the original guard clauses.

  "Belongs to" is effective board access (W2218): a `board_users` row, or
  derived org-admin access to a board in their Organization's workspaces, read
  through `Kanban.Workspaces.Policy.accessible_board_ids/1`. Each variant adds
  exactly one binding after the column binding — a subquery of
  `%{board_id: id}` rows, one per board — so a caller's positional bindings
  are unchanged and a task never appears twice.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Workspaces.Policy

  @doc """
  Restricts the query to tasks on boards the scoped user belongs to.
  Requires the base query to carry a `:column` named binding.
  """
  def apply_board_scope(query, nil), do: query
  def apply_board_scope(query, %Scope{user: nil}), do: query

  def apply_board_scope(query, %Scope{user: user}) do
    join(query, :inner, [t, column: c], a in subquery(Policy.accessible_board_ids(user.id)),
      on: a.board_id == c.board_id
    )
  end

  @doc """
  Restricts a bare task query (no column join yet) to boards the scoped
  user belongs to, adding the column join itself.
  """
  def apply_board_scope_with_column_join(query, nil), do: query
  def apply_board_scope_with_column_join(query, %Scope{user: nil}), do: query

  def apply_board_scope_with_column_join(query, %Scope{user: user}) do
    query
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t, c], a in subquery(Policy.accessible_board_ids(user.id)),
      on: a.board_id == c.board_id
    )
  end
end
