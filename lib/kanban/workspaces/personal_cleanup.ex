defmodule Kanban.Workspaces.PersonalCleanup do
  @moduledoc """
  Emptying a user's personal workspace before their account is deleted
  (W2221), so `Kanban.Workspaces.delete_personal_workspace/1` can remove it.

  Each board in the workspace is either deleted or re-homed into another
  user's personal workspace, following the placement rule of the W2217
  backfill (`priv/repo/migrations/20261018134655_backfill_personal_workspaces.exs`)
  with every disabled account skipped at every step:

    1. another enabled user's `board_users` owner row: the board goes to its
       owner;
    2. otherwise the earliest other enabled member, by
       `board_users.inserted_at` then id;
    3. otherwise the earliest enabled site admin other than the user, by
       `users.inserted_at` then id;
    4. otherwise the board is deleted, with its columns and tasks (they
       cascade).

  A board only the user uses — no `board_users` row but their own — is
  deleted outright. Rule 3 is for a board with no rows at all, and for one
  whose other members are all disabled: it never lands in a disabled
  account's workspace, where nobody could reach it.

  Under rule 3 the site admin is also made the board's owner (decided
  2026-10-21), so an enabled account can reach it: a disabled owner's row is
  demoted to `:modify` first (one owner row per board), then the admin's
  owner row is inserted. A disabled member who is enabled again gets their
  own access back, and the admin can hand ownership back with
  `Kanban.Boards.transfer_board_ownership/3`. Rules 1 and 2 never change a
  row: the new home's user is already a member.

  The caller must already have refused the deletion while the user owns a
  board other people use, which is why rule 1 only ever finds another user's
  owner row.

  Run it inside the transaction that deletes the user. The workspace's boards
  are locked `FOR UPDATE` in id order, so a concurrent membership change or
  move waits for that transaction. After it commits, pass the result's
  `:given_to_admin` grants to `report_admin_grants/2`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @type grant :: %{board: Board.t(), owner_row: BoardUser.t(), demoted_row: BoardUser.t() | nil}

  @type result :: %{
          deleted: [Board.t()],
          rehomed: [{integer(), integer()}],
          given_to_admin: [grant()]
        }

  @empty %{deleted: [], rehomed: [], given_to_admin: []}

  @doc """
  Deletes or re-homes every board in `user`'s personal workspace. Returns
  `{:ok, %{deleted: boards, rehomed: [{board_id, new_home_user_id}],
  given_to_admin: grants}}`, or `{:error, reason}` from the first write that
  failed; roll back on an error. A board re-homed under rule 3 is in both
  `:rehomed` and `:given_to_admin`; each grant holds the board, the admin's
  new owner row and the disabled owner's demoted row (`nil` when the board
  had no owner row). A user with no personal workspace gets empty lists.
  """
  @spec clear_personal_boards(User.t()) :: {:ok, result()} | {:error, term()}
  def clear_personal_boards(%User{} = user) do
    case Workspaces.get_personal_workspace(user) do
      nil -> {:ok, @empty}
      %Workspace{} = workspace -> workspace |> lock_boards() |> clear_boards(user)
    end
  end

  defp lock_boards(%Workspace{id: workspace_id}) do
    from(b in Board, where: b.workspace_id == ^workspace_id, order_by: b.id, lock: "FOR UPDATE")
    |> Repo.all()
  end

  defp clear_boards(boards, user) do
    Enum.reduce_while(boards, {:ok, @empty}, fn board, {:ok, acc} ->
      board |> clear_board(user) |> accumulate(acc)
    end)
  end

  defp accumulate({:deleted, board}, acc),
    do: {:cont, {:ok, %{acc | deleted: [board | acc.deleted]}}}

  defp accumulate({:rehomed, pair}, acc),
    do: {:cont, {:ok, %{acc | rehomed: [pair | acc.rehomed]}}}

  defp accumulate({:given_to_admin, pair, grant}, acc) do
    acc = %{acc | rehomed: [pair | acc.rehomed], given_to_admin: [grant | acc.given_to_admin]}
    {:cont, {:ok, acc}}
  end

  defp accumulate({:error, _reason} = error, _acc), do: {:halt, error}

  defp clear_board(board, user) do
    case new_home(board, user) do
      nil -> delete_board(board)
      {:member, target} -> rehome_board(board, target)
      {:admin, admin} -> give_to_admin(board, admin)
    end
  end

  defp new_home(%Board{id: board_id}, %User{id: user_id} = user) do
    rows =
      from(bu in BoardUser,
        where: bu.board_id == ^board_id,
        order_by: [asc: bu.inserted_at, asc: bu.id],
        preload: :user
      )
      |> Repo.all()

    case Enum.reject(rows, &(&1.user_id == user_id)) do
      [] when rows != [] -> nil
      others -> member_home(others) || admin_home(user)
    end
  end

  defp member_home(rows) do
    case enabled_owner(rows) || earliest_enabled(rows) do
      nil -> nil
      %User{} = member -> {:member, member}
    end
  end

  defp admin_home(user) do
    case earliest_other_admin(user) do
      nil -> nil
      %User{} = admin -> {:admin, admin}
    end
  end

  defp enabled_owner(rows),
    do: Enum.find_value(rows, &(&1.access == :owner and enabled_user(&1)))

  defp earliest_enabled(rows), do: Enum.find_value(rows, &enabled_user/1)

  defp enabled_user(%BoardUser{user: %User{disabled_at: nil} = user}), do: user
  defp enabled_user(%BoardUser{}), do: nil

  defp earliest_other_admin(%User{id: user_id}) do
    from(u in User,
      where: u.type == ^:admin and is_nil(u.disabled_at) and u.id != ^user_id,
      order_by: [asc: u.inserted_at, asc: u.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp delete_board(board) do
    case Repo.delete(board) do
      {:ok, deleted} -> {:deleted, deleted}
      {:error, _changeset} = error -> error
    end
  end

  defp rehome_board(board, target) do
    with {:ok, %Workspace{id: workspace_id}} <- Workspaces.ensure_personal_workspace(target),
         {:ok, _board} <-
           board |> Ecto.Changeset.change(workspace_id: workspace_id) |> Repo.update() do
      {:rehomed, {board.id, target.id}}
    end
  end

  # The board row is already locked FOR UPDATE, so its board_users rows cannot
  # change under us. The old owner goes first: one owner row per board.
  defp give_to_admin(board, admin) do
    with {:rehomed, pair} <- rehome_board(board, admin),
         {:ok, demoted} <- demote_owner(board),
         {:ok, owner_row} <- insert_owner(board, admin) do
      {:given_to_admin, pair, %{board: board, owner_row: owner_row, demoted_row: demoted}}
    end
  end

  defp demote_owner(%Board{id: board_id}) do
    from(bu in BoardUser, where: bu.board_id == ^board_id and bu.access == ^:owner)
    |> Repo.one()
    |> case do
      nil -> {:ok, nil}
      row -> row |> BoardUser.changeset(%{access: :modify}) |> Repo.update()
    end
  end

  defp insert_owner(%Board{id: board_id}, %User{id: admin_id}) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board_id, user_id: admin_id, access: :owner})
    |> Repo.insert()
  end

  @doc """
  Reports each rule 3 grant from `clear_personal_boards/1` once the deletion
  has committed: the `:board_given_to_site_admin` audit event, membership
  telemetry, and a `board_access_changed` notification to the admin (added
  as owner) and to the demoted owner. `deleted_user` is the account whose
  deletion made the change; the notifications carry no actor, since nobody
  chose it.
  """
  @spec report_admin_grants([grant()], User.t()) :: :ok
  def report_admin_grants(grants, %User{} = deleted_user) do
    Enum.each(grants, &report_admin_grant(&1, deleted_user))
  end

  defp report_admin_grant(%{board: board, owner_row: owner_row} = grant, deleted_user) do
    AuditLog.event(:board_given_to_site_admin,
      user_id: deleted_user.id,
      board_id: board.id,
      member_user_id: owner_row.user_id
    )

    report_row(board, owner_row, :added, deleted_user)
    report_row(board, grant.demoted_row, {:access_changed, :owner}, deleted_user)
  end

  defp report_row(_board, nil, _change, _deleted_user), do: :ok

  defp report_row(board, row, change, deleted_user) do
    BoardTelemetry.membership_changed(row, change, 0, deleted_user)

    Events.board_access_changed(board, %{id: row.user_id}, notice_kind(change),
      actor: nil,
      access: row.access,
      tokens_revoked: 0,
      membership_id: row.id,
      stamp: row.updated_at
    )
  end

  defp notice_kind(:added), do: :added
  defp notice_kind({:access_changed, _from}), do: :access_changed
end
