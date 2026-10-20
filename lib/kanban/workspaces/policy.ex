defmodule Kanban.Workspaces.Policy do
  @moduledoc """
  Effective board access and workspace management checks (D4).

  A user's effective access to a board is the **stronger** of two things:

    * **Explicit access** — their `board_users` row (`:owner`, `:modify` or
      `:read_only`), exactly as before workspaces existed.
    * **Derived access** — owner-equivalent access for an enabled org-admin of
      the Organization that owns the board's workspace. It is computed on every
      check and never written as a `board_users` row, so the one-owner-per-board
      constraint holds and removing an org-admin revokes it at once.

  Derived access is reported as `:owner`, the value every owner-gated caller
  already compares against.

  Nothing else derives access. Workspace members and guests, Organization
  members, org-admins of a different Organization, site admins and the owner
  of a personal workspace reach a board only through `board_users`. A personal
  workspace has no Organization, so its boards are `board_users`-only even for
  the workspace's owner — including the ownerless and memberless boards the
  W2217 backfill placed in other users' personal workspaces. Workspace
  placement is never read as ownership.

  Each access function here costs one query, and the list functions join the
  workspace and the caller's org-admin membership once rather than querying
  per board. `can_create_board_in?/2` costs up to three: the org-admin check,
  the Organization membership check and the workspace row check.

  `accessible_board_ids/1` is the same rule as a composable query, for reads
  that scope by board rather than load one: labels, goal children, member
  search and `Kanban.Queries.BoardScope`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @max_bigint 9_223_372_036_854_775_807

  @type access :: :owner | :modify | :read_only | nil

  @doc """
  Returns `user`'s effective access to the board: `:owner`, `:modify`,
  `:read_only`, or `nil` when they have none.

  `board` is a `%Board{}` or its id and `user` a `%User{}` or its id. An id that
  is not a positive integer that fits the column gives `nil`.

  ## Examples

      iex> effective_board_access(org_board, org_admin)
      :owner

      iex> effective_board_access(personal_board, personal_workspace_owner)
      nil

  """
  @spec effective_board_access(Board.t() | integer() | String.t() | nil, User.t() | integer()) ::
          access()
  def effective_board_access(board, user) do
    with board_id when is_integer(board_id) <- parse_id(board_id(board)),
         user_id when is_integer(user_id) <- user_id(user) do
      user_id
      |> accessible_query()
      |> where([board: b], b.id == ^board_id)
      |> select([explicit: bu, admin: a], {bu.access, not is_nil(a.organization_id)})
      |> Repo.one()
      |> combine()
    else
      _ -> nil
    end
  end

  @doc """
  Returns `{board, access}` for the board with `id`, `access` being `user`'s
  effective access or `nil`, or `nil` when no such board exists.

  It does not decide whether a board without access may be shown; that is
  `Kanban.Boards.get_board/2`'s rule for read-only boards.
  """
  @spec fetch_board(integer() | String.t() | nil, User.t()) :: {Board.t(), access()} | nil
  def fetch_board(id, %User{id: user_id}) do
    case parse_id(id) do
      nil ->
        nil

      board_id ->
        user_id
        |> accessible_query()
        |> where([board: b], b.id == ^board_id)
        |> select(
          [board: b, explicit: bu, admin: a],
          {b, bu.access, not is_nil(a.organization_id)}
        )
        |> Repo.one()
        |> case do
          nil -> nil
          {board, explicit, derived?} -> {board, combine({explicit, derived?})}
        end
    end
  end

  @doc """
  The batched variant of `effective_board_access/2`: a map from each id in
  `board_ids` that names a board to `user`'s effective access to it (`nil` for
  none), from one query.
  """
  @spec effective_board_accesses([integer()], User.t()) :: %{integer() => access()}
  def effective_board_accesses(board_ids, %User{id: user_id}) when is_list(board_ids) do
    ids = parse_ids(board_ids)

    user_id
    |> accessible_query()
    |> where([board: b], b.id in ^ids)
    |> select(
      [board: b, explicit: bu, admin: a],
      {b.id, bu.access, not is_nil(a.organization_id)}
    )
    |> Repo.all()
    |> Map.new(fn {id, explicit, derived?} -> {id, combine({explicit, derived?})} end)
  end

  @doc """
  Returns every board `user` has effective access to, each with its virtual
  `:user_access` set, from one query and without duplicates. Unsorted.

  Pass `workspace_id:` to limit the list to the boards in one workspace.
  """
  @spec list_accessible_boards(User.t(), keyword()) :: [Board.t()]
  def list_accessible_boards(%User{id: user_id}, opts \\ []) do
    ids = from(a in subquery(accessible_board_ids(user_id)), select: a.board_id)

    user_id
    |> accessible_query()
    |> where([board: b], b.id in subquery(ids))
    |> filter_workspace(Keyword.get(opts, :workspace_id))
    |> select([board: b, explicit: bu, admin: a], {b, bu.access, not is_nil(a.organization_id)})
    |> Repo.all()
    |> Enum.map(fn {board, explicit, derived?} ->
      %{board | user_access: combine({explicit, derived?})}
    end)
  end

  @doc """
  Returns a query selecting `%{board_id: id}` once for every board the user
  with `user_id` has effective access to: the boards they hold a `board_users`
  row on, united with the boards in workspaces of the Organization they are an
  enabled org-admin of.

  It costs nothing until it runs, and is meant to be joined as a subquery (or
  narrowed to its one column for `in`), so a scoping read stays one query and
  both halves use their indexes:

      from(l in Label,
        join: a in subquery(accessible_board_ids(user.id)),
        on: a.board_id == l.board_id
      )

  ## Examples

      iex> Repo.all(accessible_board_ids(org_admin.id))
      [%{board_id: 12}, %{board_id: 40}]

  """
  @spec accessible_board_ids(integer()) :: Ecto.Query.t()
  def accessible_board_ids(user_id) when is_integer(user_id) do
    derived =
      from(b in Board,
        join: w in assoc(b, :workspace),
        join: a in subquery(admin_organizations(user_id)),
        on: a.organization_id == w.organization_id,
        select: %{board_id: b.id}
      )

    from(bu in BoardUser,
      where: bu.user_id == ^user_id,
      select: %{board_id: bu.board_id},
      union: ^derived
    )
  end

  @doc """
  Returns true when `user` may manage `workspace`: it is an org workspace and
  `user` is an enabled org-admin of its Organization, read from the database.
  A personal workspace, `nil`, or any other user gives false.
  """
  @spec can_manage_workspace?(User.t(), Workspace.t() | nil) :: boolean()
  def can_manage_workspace?(%User{} = user, %Workspace{personal: false, organization_id: org_id})
      when is_integer(org_id),
      do: Organizations.org_admin?(user, org_id)

  def can_manage_workspace?(_user, _workspace), do: false

  @doc """
  Returns true when `user` may create a board in `workspace`: an unarchived org
  workspace whose Organization `user` is an enabled org-admin of, or on which
  they hold a `:member` row while still in its Organization. A guest does not
  create boards there; their new boards go to their personal workspace. Read
  from the database.
  """
  @spec can_create_board_in?(User.t(), Workspace.t() | nil) :: boolean()
  def can_create_board_in?(
        %User{} = user,
        %Workspace{personal: false, archived_at: nil, organization_id: org_id} = workspace
      )
      when is_integer(org_id) do
    can_manage_workspace?(user, workspace) or
      (Organizations.member?(user, org_id) and member_row?(workspace, user))
  end

  def can_create_board_in?(_user, _workspace), do: false

  defp member_row?(%Workspace{id: workspace_id}, %User{id: user_id}) do
    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
      where: m.role == ^:member
    )
    |> Repo.exists?()
  end

  # Every board, its workspace (a left join, so a board read while
  # boards.workspace_id is still empty, as during the W2217 backfill, keeps its
  # explicit access), the caller's board_users row (if any) and the
  # caller's enabled org-admin membership of the workspace's Organization (if
  # any). A personal workspace has no organization_id, so the admin join never
  # matches it. A user has at most one membership and one board_users row per
  # board, so no board appears twice.
  defp accessible_query(user_id) do
    from(b in Board,
      as: :board,
      left_join: w in assoc(b, :workspace),
      as: :workspace,
      left_join: bu in BoardUser,
      as: :explicit,
      on: bu.board_id == b.id and bu.user_id == ^user_id,
      left_join: a in subquery(admin_organizations(user_id)),
      as: :admin,
      on: a.organization_id == w.organization_id
    )
  end

  defp filter_workspace(query, nil), do: query

  defp filter_workspace(query, workspace_id) when is_integer(workspace_id),
    do: where(query, [board: b], b.workspace_id == ^workspace_id)

  defp admin_organizations(user_id) do
    from(m in OrganizationMember,
      join: u in assoc(m, :user),
      where: m.user_id == ^user_id and m.role == ^:org_admin and is_nil(u.disabled_at),
      select: %{organization_id: m.organization_id}
    )
  end

  defp combine(nil), do: nil
  defp combine({_explicit, true}), do: :owner
  defp combine({explicit, false}), do: explicit

  defp board_id(%Board{id: id}), do: id
  defp board_id(id), do: id

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id), do: id
  defp user_id(_user), do: nil

  defp parse_ids(ids), do: ids |> Enum.map(&parse_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
