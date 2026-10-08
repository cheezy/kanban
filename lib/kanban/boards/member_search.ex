defmodule Kanban.Boards.MemberSearch do
  @moduledoc """
  Board-scoped member lookups for comment `@mentions`: the autocomplete search
  and the membership check that decides which mentioned ids are kept and
  rendered (see `Kanban.Tasks.Mentions`).

  Unlike `Kanban.Boards.Membership`, which reads across every user and is
  admin-gated, everything here is confined to one board.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.search_board_members/4` and `Boards.members_among/2`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo

  @max_limit 20
  @max_query_length 100

  @doc """
  Searches `board`'s members for the mention autocomplete.

  Disabled users are never returned, since they can no longer act on a mention.
  Matches `query` case-insensitively against the member's name or email
  (`%` and `_` match literally) and returns at most `limit` results, `limit`
  being clamped to 1..#{@max_limit}. An empty query returns the first members
  by display name. Results are `%{id, name, email}` maps ordered by display
  name (name, else email), then id.

  The scope's user must be a member of the board (any access level);
  otherwise — including a non-member viewing a public read-only board —
  returns `{:error, :unauthorized}`, so members of a board cannot be
  enumerated from outside it.

  ## Examples

      iex> search_board_members(scope, board, "ad", 5)
      {:ok, [%{id: 1, name: "Ada", email: "ada@example.com"}]}

      iex> search_board_members(outsider_scope, board, "ad", 5)
      {:error, :unauthorized}

  """
  def search_board_members(scope, %Board{id: board_id}, query, limit)
      when is_binary(query) and is_integer(limit) do
    if member?(scope, board_id) do
      {:ok, run_search(board_id, query, clamp(limit))}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns `%{id, name, email}` for each user in `user_ids` who is currently a
  member of the board `board_id`. Ids of non-members are silently absent.

  Performs no authorization: the caller must derive `board_id` server-side
  (for comments, from the comment's task) rather than accept it from a client.
  Issues no query when `user_ids` is empty.

  ## Options

    * `:active_only` — when `true`, disabled users are absent too. Use it to
      decide who may be newly mentioned; leave it off to render existing
      mentions, so a member disabled later still shows by name.
  """
  def members_among(board_id, user_ids, opts \\ [])

  def members_among(_board_id, [], _opts), do: []

  def members_among(board_id, user_ids, opts) when is_integer(board_id) and is_list(user_ids) do
    BoardUser
    |> join(:inner, [bu], u in assoc(bu, :user))
    |> where([bu, u], bu.board_id == ^board_id and u.id in ^user_ids)
    |> maybe_active_only(Keyword.get(opts, :active_only, false))
    |> select([_bu, u], %{id: u.id, name: u.name, email: u.email})
    |> Repo.all()
  end

  defp maybe_active_only(query, true), do: where(query, [_bu, u], is_nil(u.disabled_at))
  defp maybe_active_only(query, _), do: query

  defp member?(%{user: %{id: user_id}}, board_id) when is_integer(user_id) do
    BoardUser
    |> where([bu], bu.board_id == ^board_id and bu.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp member?(_scope, _board_id), do: false

  defp run_search(board_id, query, limit) do
    pattern = "%" <> escape_like(query) <> "%"

    BoardUser
    |> join(:inner, [bu], u in assoc(bu, :user))
    |> where([bu], bu.board_id == ^board_id)
    |> maybe_active_only(true)
    |> where([_bu, u], ilike(u.name, ^pattern) or ilike(u.email, ^pattern))
    |> order_by([_bu, u], asc: fragment("lower(coalesce(nullif(?, ''), ?))", u.name, u.email))
    |> order_by([_bu, u], asc: u.id)
    |> limit(^limit)
    |> select([_bu, u], %{id: u.id, name: u.name, email: u.email})
    |> Repo.all()
  end

  defp escape_like(query) do
    query
    |> String.trim()
    |> String.slice(0, @max_query_length)
    |> String.replace(["\\", "%", "_"], &("\\" <> &1))
  end

  defp clamp(limit), do: limit |> max(1) |> min(@max_limit)
end
