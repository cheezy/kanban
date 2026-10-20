defmodule Kanban.Boards do
  @moduledoc """
  The Boards context.

  Board membership queries, including the `over_cap_boards/0` report of
  personal-workspace boards over the free member cap, live in
  `Kanban.Boards.Membership` and membership
  writes (add, change access, remove), with the free-board member cap and its
  `member_cap_status/1` read, in `Kanban.Boards.MembershipChanges`.
  Board creation lives in `Kanban.Boards.Creation`, and the scoped metrics
  reads behind the Boards index, the board header and the all-boards rollups
  in `Kanban.Boards.Dashboard`. All of them are delegated to below; the access
  functions (`list_boards/1`, `get_board/2`, `owner?/2`, `can_modify?/2`) stay
  here and route through `Kanban.Workspaces.Policy`, so an org-admin gets
  owner-equivalent access to every board in their Organization's workspaces
  without a `board_users` row.
  """

  use Gettext, backend: KanbanWeb.Gettext
  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.Creation
  alias Kanban.Boards.Dashboard
  alias Kanban.Boards.MemberSearch
  alias Kanban.Boards.Membership
  alias Kanban.Boards.MembershipChanges
  alias Kanban.Boards.OwnershipTransfer
  alias Kanban.Workspaces.Policy

  @max_bigint 9_223_372_036_854_775_807

  @doc """
  Returns the list of boards for a given user with their access level.

  Each board will have a virtual `:user_access` field containing the user's
  effective access level (`Kanban.Workspaces.Policy`): their `board_users`
  access, or `:owner` for an org-admin of the Organization that owns the
  board's workspace. Every board is listed once, from one query.
  Boards are sorted by access level (owner first, modify second, read_only last),
  then by creation date (most recent first) within each access level.

  ## Examples

      iex> list_boards(user)
      [%Board{user_access: :owner}, ...]

  """
  def list_boards(user) do
    user
    |> Policy.list_accessible_boards()
    |> Enum.sort_by(&board_sort_key/1, &board_sort_compare/2)
  end

  @doc """
  Returns `true` when the user has access to at least one board.

  Cheaper than `list_boards/1` when only existence matters (e.g. landing-page
  CTAs that branch on "has any boards yet?").
  """
  def user_has_boards?(%User{id: user_id}) do
    BoardUser
    |> where(user_id: ^user_id)
    |> Repo.exists?()
  end

  def user_has_boards?(_), do: false

  ## Membership

  defdelegate board_counts_by_user(), to: Membership
  defdelegate over_cap_boards(), to: Membership

  # Board-scoped member lookups for comment @mentions (see Kanban.Boards.MemberSearch).
  defdelegate search_board_members(scope, board, query, limit), to: MemberSearch
  defdelegate members_among(board_id, user_ids, opts \\ []), to: MemberSearch

  defp board_sort_key(board) do
    access_priority =
      case board.user_access do
        :owner -> 0
        :modify -> 1
        :read_only -> 2
      end

    {access_priority, NaiveDateTime.to_erl(board.inserted_at)}
  end

  defp board_sort_compare({priority_a, time_a}, {priority_b, time_b}) do
    if priority_a == priority_b do
      time_a >= time_b
    else
      priority_a < priority_b
    end
  end

  ## Scoped metrics reads (see Kanban.Boards.Dashboard)

  defdelegate list_boards_with_metrics(user, opts \\ []), to: Dashboard
  defdelegate get_board_metrics(user, board_id, opts \\ []), to: Dashboard
  defdelegate workspace_metrics(user, opts \\ []), to: Dashboard
  defdelegate workspace_metrics_from(boards), to: Dashboard
  defdelegate list_workspace_members(user, opts \\ []), to: Dashboard
  defdelegate list_board_members(board_id), to: Dashboard

  @doc """
  Gets a single board with authorization check.

  Returns `{:ok, board}` if found and accessible, `{:error, :not_found}` otherwise.
  An `id` that is not a positive integer that fits the column (`nil`, `"abc"`,
  `"99999999999999999999"`) is `{:error, :not_found}`.

  `user_access` is the user's effective access (`Kanban.Workspaces.Policy`).
  For read-only boards (read_only: true), users without access can see the
  board with user_access: nil. For private boards (read_only: false), only
  users with effective access can.

  ## Examples

      iex> get_board(123, user)
      {:ok, %Board{}}

      iex> get_board(456, user)
      {:error, :not_found}

  """
  # Postgrex raises on an integer past bigint, so a URL-supplied id is bounded
  # here before it is queried.
  def get_board(id, user) when is_integer(id) and id > 0 and id <= @max_bigint do
    case Policy.fetch_board(id, user) do
      nil ->
        {:error, :not_found}

      {%Board{} = board, nil} ->
        if board.read_only, do: {:ok, %{board | user_access: nil}}, else: {:error, :not_found}

      {%Board{} = board, access} ->
        {:ok, %{board | user_access: access}}
    end
  end

  def get_board(id, user) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_board(int_id, user)
      _ -> {:error, :not_found}
    end
  end

  def get_board(_id, _user), do: {:error, :not_found}

  @doc """
  Same as `get_board/2` but raises `Ecto.NoResultsError` if not found.
  """
  def get_board!(id, user) do
    case get_board(id, user) do
      {:ok, board} -> board
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Board
    end
  end

  @doc """
  Gets the access level for a user on a board.

  Returns the user's effective access level (:owner, :read_only, :modify) or
  nil if they have no access: the stronger of their `board_users` row and the
  owner-equivalent access an org-admin derives for boards in their
  Organization's workspaces (`Kanban.Workspaces.Policy.effective_board_access/2`).

  ## Examples

      iex> get_user_access(board_id, user_id)
      :owner

  """
  def get_user_access(board_id, user_id) do
    Policy.effective_board_access(board_id, user_id)
  end

  @doc """
  Checks if a user has owner access to a board.

  ## Examples

      iex> owner?(board, user)
      true

  """
  def owner?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) == :owner
  end

  @doc """
  Checks if a user can modify a board (owner or modify access).

  ## Examples

      iex> can_modify?(board, user)
      true

  """
  def can_modify?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) in [:owner, :modify]
  end

  ## Creation (see Kanban.Boards.Creation)

  defdelegate create_board(user, attrs \\ %{}, opts \\ []), to: Creation
  defdelegate create_ai_optimized_board(user, attrs \\ %{}, opts \\ []), to: Creation

  @doc """
  Updates a board.

  ## Examples

      iex> update_board(board, %{name: "New Name"})
      {:ok, %Board{}}

      iex> update_board(board, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_board(%Board{} = board, attrs, user) do
    if owner?(board, user) do
      changeset = Board.owner_changeset(board, attrs)

      changeset
      |> Repo.update()
      |> BoardTelemetry.updated(changeset, user)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a board. Owner-only.

  ## Examples

      iex> delete_board(board, user)
      {:ok, %Board{}}

  """
  def delete_board(%Board{} = board, user) do
    if owner?(board, user) do
      board
      |> Repo.delete()
      |> BoardTelemetry.deleted(user)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking board changes.

  ## Examples

      iex> change_board(board)
      %Ecto.Changeset{data: %Board{}}

  """
  def change_board(%Board{} = board, attrs \\ %{}) do
    Board.changeset(board, attrs)
  end

  defdelegate add_user_to_board(board, user, access, current_user), to: MembershipChanges
  defdelegate add_invited_user(board, user, access, actor), to: MembershipChanges
  defdelegate remove_user_from_board(board, user, current_user), to: MembershipChanges
  defdelegate update_user_access(board, user, new_access, current_user), to: MembershipChanges
  defdelegate member_cap_status(board), to: MembershipChanges

  @doc """
  Makes `new_owner`, an existing member, the explicit owner of `board`. See
  `Kanban.Boards.OwnershipTransfer.transfer_board_ownership/3`.
  """
  defdelegate transfer_board_ownership(board, new_owner, actor), to: OwnershipTransfer

  @doc """
  Lists the members `board`'s ownership may be transferred to, or `[]` when
  `actor` may not transfer it. See
  `Kanban.Boards.OwnershipTransfer.list_ownership_candidates/2`.
  """
  defdelegate list_ownership_candidates(board, actor), to: OwnershipTransfer

  @doc """
  Lists all users associated with a board along with their access level.

  Users are sorted by access level (owner first, then modify, then read_only),
  and then alphabetically by email within each access level.

  ## Examples

      iex> list_board_users(board)
      [%{user: %User{}, access: :owner}, ...]

  """
  def list_board_users(%Board{id: board_id}) do
    BoardUser
    |> where([bu], bu.board_id == ^board_id)
    |> join(:inner, [bu], u in assoc(bu, :user))
    |> select([bu, u], %{user: u, access: bu.access})
    |> Repo.all()
    |> Enum.sort_by(fn %{user: user, access: access} ->
      access_priority =
        case access do
          :owner -> 0
          :modify -> 1
          :read_only -> 2
        end

      {access_priority, user.email}
    end)
  end

  @doc """
  Updates field visibility settings for a board.
  Only board owners can update field visibility.
  Broadcasts changes to all connected clients.

  ## Examples

      iex> update_field_visibility(board, %{"complexity" => true}, user)
      {:ok, %Board{}}

      iex> update_field_visibility(board, %{"complexity" => true}, non_owner_user)
      {:error, :unauthorized}

  """
  def update_field_visibility(%Board{} = board, field_visibility, user) do
    if owner?(board, user) do
      changeset = Board.changeset(board, %{field_visibility: field_visibility})

      changeset
      |> Repo.update()
      |> BoardTelemetry.field_visibility_changed(changeset, user)
      |> case do
        {:ok, updated_board} ->
          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{board.id}",
            {:field_visibility_updated, updated_board.field_visibility}
          )

          {:ok, updated_board}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end
end
