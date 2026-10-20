defmodule Kanban.Accounts.AccountDeletion do
  @moduledoc """
  Self-service account deletion (W2221), available to every user, free or
  paid, from the Danger zone of the account settings page.

  Three blockers refuse a deletion, each listed with what to do about it:

    * `{:shared_board, board}` — the user holds the explicit owner row of a
      board that other people are members of. They transfer ownership
      (`Kanban.Boards.transfer_board_ownership/3`) or remove the other
      members first, so no shared board is left without an owner.
    * `{:last_org_admin, organization}` — the user is the last enabled
      org-admin of an Organization that has other members. Only a site admin
      can appoint another org-admin, and this flow never does.
    * `:last_site_admin` — the user is the last enabled site admin.

  `delete_own_account/3` checks the confirmation phrase and the password
  before taking any lock, then re-checks every blocker inside the deleting
  transaction, under row locks, so a change made at the same moment cannot
  slip past them. In that one transaction it:

    1. revokes the open invitations the user sent;
    2. empties their personal workspace (`Kanban.Workspaces.clear_personal_boards/1`):
       boards only they use are deleted, any board others still use is
       re-homed to the earliest remaining member's personal workspace;
    3. deletes every one of their `users_tokens` rows (sessions, email
       tokens);
    4. deletes the personal workspace, then the user row.

  The user row's foreign keys remove their API tokens (board and workspace
  tokens), board memberships, Organization membership and workspace member
  rows, and nilify the attribution columns of tasks, comments and history.

  After commit it records the `:account_self_deleted` audit event with the
  user id only — never the email — reports each deleted board, and broadcasts
  `{Kanban.Boards, :members_changed, board_id}` for every board whose
  membership changed. The caller disconnects the returned session tokens'
  open LiveViews (`KanbanWeb.UserAuth.disconnect_sessions/1`).

  Exposed through the `Kanban.Accounts` facade via `defdelegate`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.AdminManagement
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.AuditLog
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.RateLimit
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation

  @confirmation_phrase "delete my account"

  @type blocker ::
          :last_site_admin | {:last_org_admin, Organization.t()} | {:shared_board, Board.t()}

  @type error ::
          :invalid_confirmation
          | :rate_limited
          | :not_found
          | :invalid_password
          | {:blocked, [blocker()]}

  @doc """
  The phrase the user types to confirm the deletion. It is the same in every
  locale, so the check never depends on the interface language.
  """
  @spec confirmation_phrase() :: String.t()
  def confirmation_phrase, do: @confirmation_phrase

  @doc """
  Returns what stops `user` deleting their account, `[]` when nothing does:
  `:last_site_admin` first, then `{:last_org_admin, organization}`, then one
  `{:shared_board, board}` per shared board they own, by name.

  This read is for display and takes no lock; `delete_own_account/3` checks
  again under locks.
  """
  @spec deletion_blockers(User.t()) :: [blocker()]
  def deletion_blockers(%User{} = user) do
    site_admin_blockers(user) ++ listed_org_admin_blockers(user) ++ shared_board_blockers(user)
  end

  @doc """
  Deletes the account of the scope's user once `password` is theirs and
  `confirmation` is the confirmation phrase (surrounding whitespace ignored).

  Returns `{:ok, %{user: deleted_user, session_tokens: tokens}}`, where
  `tokens` are the deleted session tokens whose open LiveViews the caller
  should disconnect. Changes nothing and returns:

    * `{:error, :invalid_confirmation}` — the phrase does not match
    * `{:error, :rate_limited}` — too many attempts lately (every attempt
      with the right phrase counts, atomically, before the password is hashed)
    * `{:error, :not_found}` — the account is already gone or disabled
    * `{:error, :invalid_password}` — the password is wrong
    * `{:error, {:blocked, blockers}}` — see `deletion_blockers/1`

  ## Examples

      iex> delete_own_account(scope, "correct password", "delete my account")
      {:ok, %{user: %User{}, session_tokens: [%UserToken{}]}}

      iex> delete_own_account(scope, "wrong", "delete my account")
      {:error, :invalid_password}

  """
  @spec delete_own_account(Scope.t(), String.t(), String.t()) ::
          {:ok, %{user: User.t(), session_tokens: [UserToken.t()]}} | {:error, error()}
  def delete_own_account(%Scope{user: %User{id: user_id}}, password, confirmation) do
    with :ok <- check_confirmation(confirmation),
         :ok <- check_rate_limit(user_id),
         {:ok, user} <- fetch_enabled_user(user_id),
         :ok <- check_password(user, password),
         {:ok, deleted} <- delete_locked(user) do
      {:ok, report_deletion(deleted)}
    end
  end

  def delete_own_account(_scope, _password, _confirmation), do: {:error, :not_found}

  defp check_confirmation(confirmation) when is_binary(confirmation) do
    if String.trim(confirmation) == @confirmation_phrase,
      do: :ok,
      else: {:error, :invalid_confirmation}
  end

  defp check_confirmation(_confirmation), do: {:error, :invalid_confirmation}

  # Every attempt that gets past the confirmation phrase is counted here, with
  # one atomic increment-and-compare, before the password is hashed. Peeking
  # first and recording the failure after bcrypt would let parallel requests
  # all read the same count and all reach bcrypt.
  defp check_rate_limit(user_id) do
    case RateLimit.check(:account_delete, identity: "user:#{user_id}") do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
    end
  end

  defp fetch_enabled_user(user_id) do
    case Repo.get(User, user_id) do
      %User{disabled_at: nil} = user -> {:ok, user}
      _gone_or_disabled -> {:error, :not_found}
    end
  end

  # Bcrypt is slow on purpose, so the password is checked before any lock. The
  # attempt was already counted by check_rate_limit/1.
  defp check_password(user, password) do
    if is_binary(password) and User.valid_password?(user, password),
      do: :ok,
      else: {:error, :invalid_password}
  end

  defp delete_locked(user) do
    Repo.transact(fn ->
      with {:ok, user} <- lock_user(user),
           :ok <- ensure_no_blockers(user) do
        delete_rows(user)
      end
    end)
  end

  # The board ids are read first, for the broadcasts: the memberships go with
  # the user row.
  defp delete_rows(user) do
    board_ids = member_board_ids(user)

    with {_revoked, _} <- revoke_sent_invitations(user),
         {:ok, cleared} <- Workspaces.clear_personal_boards(user),
         {_count, tokens} <- delete_user_tokens(user),
         {:ok, _workspace} <- Workspaces.delete_personal_workspace(user),
         {:ok, deleted} <- Repo.delete(user) do
      {:ok, %{user: deleted, tokens: tokens, cleared: cleared, board_ids: board_ids}}
    end
  end

  # An admin also locks every other enabled admin row, in id order, so two
  # admins deleting themselves at once cannot both see the other as the
  # remaining admin. Everyone else locks only their own row, which also makes a
  # concurrent ownership transfer to them wait (it takes FOR KEY SHARE).
  defp lock_user(%User{id: user_id, type: type}) do
    from(u in User, where: u.id == ^user_id, order_by: u.id, lock: "FOR UPDATE")
    |> maybe_lock_admins(type)
    |> Repo.all()
    |> Enum.find(&(&1.id == user_id))
    |> case do
      %User{disabled_at: nil} = user -> {:ok, user}
      _gone_or_disabled -> {:error, :not_found}
    end
  end

  defp maybe_lock_admins(query, :admin),
    do: or_where(query, [u], u.type == ^:admin and is_nil(u.disabled_at))

  defp maybe_lock_admins(query, _type), do: query

  defp ensure_no_blockers(user) do
    lock_owned_boards(user)

    case collect_blockers(user) do
      [] -> :ok
      blockers -> {:error, {:blocked, blockers}}
    end
  end

  # FOR UPDATE on the boards the user owns serializes with a member being
  # added at the same moment: adding a member locks the board row first.
  defp lock_owned_boards(%User{id: user_id}) do
    from(b in Board,
      join: bu in BoardUser,
      on: bu.board_id == b.id and bu.user_id == ^user_id and bu.access == ^:owner,
      order_by: b.id,
      lock: "FOR UPDATE",
      select: b.id
    )
    |> Repo.all()
  end

  defp collect_blockers(user) do
    site_admin_blockers(user) ++ org_admin_blockers(user) ++ shared_board_blockers(user)
  end

  defp site_admin_blockers(user) do
    if AdminManagement.last_admin?(user), do: [:last_site_admin], else: []
  end

  defp org_admin_blockers(user) do
    case Organizations.ensure_not_last_working_org_admin(user) do
      :ok ->
        []

      {:error, :last_org_admin} ->
        [{:last_org_admin, Organizations.get_membership(user).organization}]
    end
  end

  # The same rule as Organizations.ensure_not_last_working_org_admin/1, read
  # without its lock on the Organization row, which only the deleting
  # transaction needs: an enabled org-admin whose Organization has other
  # members and no other enabled org-admin.
  defp listed_org_admin_blockers(%User{id: user_id}) do
    from(m in OrganizationMember,
      as: :membership,
      join: me in User,
      on: me.id == m.user_id and is_nil(me.disabled_at),
      join: o in assoc(m, :organization),
      where: m.user_id == ^user_id and m.role == ^:org_admin,
      where: exists(other_members_query(user_id)),
      where: not exists(other_enabled_org_admins_query(user_id)),
      select: o
    )
    |> Repo.all()
    |> Enum.map(&{:last_org_admin, &1})
  end

  defp other_members_query(user_id) do
    from(x in OrganizationMember,
      where:
        x.organization_id == parent_as(:membership).organization_id and x.user_id != ^user_id,
      select: 1
    )
  end

  defp other_enabled_org_admins_query(user_id) do
    from(a in OrganizationMember,
      join: u in User,
      on: u.id == a.user_id and is_nil(u.disabled_at),
      where:
        a.organization_id == parent_as(:membership).organization_id and a.user_id != ^user_id and
          a.role == ^:org_admin,
      select: 1
    )
  end

  defp shared_board_blockers(%User{id: user_id}) do
    from(b in Board,
      as: :board,
      join: bu in BoardUser,
      on: bu.board_id == b.id and bu.user_id == ^user_id and bu.access == ^:owner,
      where:
        exists(
          from(o in BoardUser,
            where: o.board_id == parent_as(:board).id and o.user_id != ^user_id,
            select: 1
          )
        ),
      order_by: [asc: b.name, asc: b.id]
    )
    |> Repo.all()
    |> Enum.map(&{:shared_board, &1})
  end

  defp member_board_ids(%User{id: user_id}) do
    from(bu in BoardUser, where: bu.user_id == ^user_id, select: bu.board_id)
    |> Repo.all()
  end

  # Before the user row goes: its foreign key nilifies invited_by_id.
  defp revoke_sent_invitations(%User{id: user_id}) do
    Invitation.open_query()
    |> where([i], i.invited_by_id == ^user_id)
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])
  end

  # RETURNING, so a session token issued while the password was being checked
  # is deleted and disconnected too.
  defp delete_user_tokens(%User{id: user_id}) do
    from(t in UserToken, where: t.user_id == ^user_id, select: t)
    |> Repo.delete_all()
  end

  defp report_deletion(%{user: user, tokens: tokens, cleared: cleared, board_ids: board_ids}) do
    AuditLog.event(:account_self_deleted, user_id: user.id)
    report_boards(user, cleared, board_ids)

    %{user: user, session_tokens: Enum.filter(tokens, &(&1.context == "session"))}
  end

  defp report_boards(user, %{deleted: deleted, rehomed: rehomed}, board_ids) do
    Enum.each(deleted, &BoardTelemetry.deleted({:ok, &1}, user))

    rehomed_ids = Enum.map(rehomed, &elem(&1, 0))
    broadcast_changed(board_ids ++ rehomed_ids, MapSet.new(deleted, & &1.id))
  end

  defp broadcast_changed(board_ids, deleted_ids) do
    board_ids
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(deleted_ids, &1))
    |> Enum.each(&broadcast_members_changed/1)
  end

  defp broadcast_members_changed(board_id) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {Kanban.Boards, :members_changed, board_id}
    )
  end
end
