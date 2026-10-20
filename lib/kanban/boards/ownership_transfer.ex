defmodule Kanban.Boards.OwnershipTransfer do
  @moduledoc """
  Handing a board's explicit ownership to another of its members (W2221).

  A board has at most one `board_users` row with `:owner` access (the partial
  unique index `board_users_one_owner_per_board`). A transfer changes that row
  and the new owner's row itself, in one transaction: the old owner is demoted
  to `:modify` first, then the new owner is promoted. It never goes through
  `Kanban.Boards.update_user_access/4`, which refuses to demote the owner's own
  row with `{:error, :owner_required}`.

  Who may transfer:

    * the board's explicit owner (their own `board_users` owner row), or
    * an enabled org-admin of the Organization whose workspace holds the
      board. Derived org-admin access does not reach a board in a personal
      workspace.

  The new owner must already be a member of the board and their account must
  be enabled. When the board sits in a personal workspace it moves into the new
  owner's personal workspace in the same transaction, so a personal board
  always lives with its owner; a board in an Organization workspace stays
  where it is.

  After commit each changed row is reported as
  `Kanban.Boards.MembershipChanges` reports an access change: telemetry, the
  `{Kanban.Boards, :members_changed, board_id}` broadcast on `"board:<id>"`
  and a `board_access_changed` notification to each affected user other than
  the actor.

  Exposed through the `Kanban.Boards` facade via `defdelegate`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Events
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @max_bigint 9_223_372_036_854_775_807

  @type error :: :not_found | :unauthorized | :not_a_member | :already_owner | :user_disabled

  @doc """
  Makes `new_owner` the explicit owner of `board`, acting as `actor`.

  `board` and `new_owner` are structs or ids and are re-read and locked in the
  transaction. Returns `{:ok, board}` (with its possibly new `workspace_id`),
  or changes nothing and returns:

    * `{:error, :not_found}` — no such board or user
    * `{:error, :unauthorized}` — `actor` is neither the board's explicit owner
      nor an enabled org-admin of the Organization holding it
    * `{:error, :user_disabled}` — the new owner's account is disabled
    * `{:error, :not_a_member}` — the new owner has no row on the board
    * `{:error, :already_owner}` — the new owner already owns it

  ## Examples

      iex> transfer_board_ownership(board, member, owner)
      {:ok, %Board{}}

      iex> transfer_board_ownership(board, outsider, owner)
      {:error, :not_a_member}

  """
  @spec transfer_board_ownership(
          Board.t() | integer() | String.t(),
          User.t() | integer() | String.t(),
          User.t()
        ) :: {:ok, Board.t()} | {:error, error()}
  def transfer_board_ownership(board, new_owner, %User{} = actor) do
    fn -> transfer_locked(id_of(board), id_of(new_owner), actor) end
    |> Repo.transact()
    |> report_transfer(actor)
  end

  defp transfer_locked(board_id, new_owner_id, actor) do
    with {:ok, board, workspace} <- lock_authorized_board(board_id, actor),
         {:ok, new_owner, changes} <- promote(board, new_owner_id),
         {:ok, board} <- follow_owner(board, workspace, new_owner) do
      {:ok, {board, changes}}
    end
  end

  defp promote(board, new_owner_id) do
    with {:ok, new_owner, new_row} <- lock_new_owner(board, new_owner_id),
         {:ok, changes} <- swap_owner_rows(lock_owner_row(board), new_row) do
      {:ok, new_owner, changes}
    end
  end

  defp lock_authorized_board(board_id, actor) do
    with {:ok, board} <- lock_board(board_id) do
      workspace = Repo.get!(Workspace, board.workspace_id)

      if authorized?(board, workspace, actor),
        do: {:ok, board, workspace},
        else: {:error, :unauthorized}
    end
  end

  defp lock_new_owner(board, new_owner_id) do
    with {:ok, new_owner} <- lock_user(new_owner_id),
         {:ok, new_row} <- lock_new_owner_row(board, new_owner) do
      {:ok, new_owner, new_row}
    end
  end

  defp lock_board(nil), do: {:error, :not_found}

  defp lock_board(board_id) do
    case from(b in Board, where: b.id == ^board_id, lock: "FOR UPDATE") |> Repo.one() do
      %Board{} = board -> {:ok, board}
      nil -> {:error, :not_found}
    end
  end

  defp authorized?(board, workspace, actor),
    do: owner_row?(board, actor) or org_admin_of_workspace?(workspace, actor)

  defp owner_row?(%Board{id: board_id}, %User{id: user_id}) do
    from(bu in BoardUser,
      where: bu.board_id == ^board_id and bu.user_id == ^user_id and bu.access == ^:owner
    )
    |> Repo.exists?()
  end

  defp org_admin_of_workspace?(%Workspace{personal: false, organization_id: org_id}, actor)
       when is_integer(org_id),
       do: Organizations.org_admin?(actor, org_id)

  defp org_admin_of_workspace?(_workspace, _actor), do: false

  # FOR KEY SHARE conflicts only with a FOR UPDATE on the user row, which the
  # account deletion takes, so a transfer to someone mid-deletion waits for it.
  defp lock_user(nil), do: {:error, :not_found}

  defp lock_user(user_id) do
    case from(u in User, where: u.id == ^user_id, lock: "FOR KEY SHARE") |> Repo.one() do
      nil -> {:error, :not_found}
      %User{disabled_at: nil} = user -> {:ok, user}
      %User{} -> {:error, :user_disabled}
    end
  end

  defp lock_new_owner_row(%Board{id: board_id}, %User{id: user_id}) do
    from(bu in BoardUser,
      where: bu.board_id == ^board_id and bu.user_id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_a_member}
      %BoardUser{access: :owner} -> {:error, :already_owner}
      row -> {:ok, row}
    end
  end

  defp lock_owner_row(%Board{id: board_id}) do
    from(bu in BoardUser,
      where: bu.board_id == ^board_id and bu.access == ^:owner,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # The old owner goes first: the partial unique index allows one owner row.
  # An ownerless board (possible in an Organization workspace) only promotes.
  defp swap_owner_rows(nil, new_row) do
    with {:ok, promoted} <- set_access(new_row, :owner) do
      {:ok, [{promoted, new_row.access}]}
    end
  end

  defp swap_owner_rows(old_row, new_row) do
    with {:ok, demoted} <- set_access(old_row, :modify),
         {:ok, promoted} <- set_access(new_row, :owner) do
      {:ok, [{demoted, :owner}, {promoted, new_row.access}]}
    end
  end

  defp set_access(row, access) do
    row
    |> BoardUser.changeset(%{access: access})
    |> Repo.update()
  end

  defp follow_owner(board, %Workspace{personal: true}, new_owner) do
    with {:ok, %Workspace{id: target_id}} <- Workspaces.ensure_personal_workspace(new_owner) do
      board |> Ecto.Changeset.change(workspace_id: target_id) |> Repo.update()
    end
  end

  defp follow_owner(board, _org_workspace, _new_owner), do: {:ok, board}

  defp report_transfer({:ok, {board, changes}}, actor) do
    Enum.each(changes, fn {row, from} ->
      BoardTelemetry.membership_changed(row, {:access_changed, from}, 0, actor)
      notify_member(board, row, actor)
    end)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board.id}",
      {Kanban.Boards, :members_changed, board.id}
    )

    {:ok, board}
  end

  defp report_transfer({:error, _reason} = error, _actor), do: error

  defp notify_member(_board, %BoardUser{user_id: user_id}, %User{id: user_id}), do: :ok

  defp notify_member(board, %BoardUser{} = row, actor) do
    Events.board_access_changed(board, %{id: row.user_id}, :access_changed,
      actor: actor,
      access: row.access,
      tokens_revoked: 0,
      membership_id: row.id,
      stamp: row.updated_at
    )
  end

  @doc """
  Returns the members `board`'s ownership may be transferred to, as `actor`
  sees them: enabled users with a non-owner row on it, ordered by name then
  email. Each entry is a map with `:id`, `:name` and `:email`.

  Only someone allowed to transfer the board sees its members here: an
  `actor` who is neither its explicit owner nor an enabled org-admin of the
  Organization holding it gets `[]`.
  """
  @spec list_ownership_candidates(Board.t(), User.t()) :: [
          %{id: integer(), name: String.t() | nil, email: String.t()}
        ]
  def list_ownership_candidates(%Board{} = board, %User{} = actor) do
    workspace = Repo.get!(Workspace, board.workspace_id)

    if authorized?(board, workspace, actor), do: candidates(board), else: []
  end

  defp candidates(%Board{id: board_id}) do
    from(bu in BoardUser,
      join: u in assoc(bu, :user),
      where: bu.board_id == ^board_id and bu.access != ^:owner and is_nil(u.disabled_at),
      order_by: [asc_nulls_last: u.name, asc: u.email],
      select: %{id: u.id, name: u.name, email: u.email}
    )
    |> Repo.all()
  end

  defp id_of(%{id: id}), do: id_of(id)
  defp id_of(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp id_of(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> id_of(int)
      _ -> nil
    end
  end

  defp id_of(_id), do: nil
end
