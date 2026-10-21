defmodule Kanban.Workspaces.InvitationAcceptance do
  @moduledoc """
  Accepts a workspace or board invitation (W2219). Called through
  `Kanban.Workspaces.Invitations.accept/2` and `accept_registered/1`.

  Everything happens in one transaction, wrapped in
  `Kanban.Telemetry.AfterCommit.after_commit/1`:

    1. The invitation row is locked and must be pending (not accepted,
       revoked or expired).
    2. `user`'s email must match the invited address, ignoring case and
       surrounding space, and `user` must be confirmed and enabled, read from
       the database.
    3. A **workspace invitation** (it has a `role`) needs a live org
       workspace. The Organization row is locked and the invitation's sender
       must still be an enabled org-admin of it. Then `user` joins it as a
       `:member` through `Kanban.Organizations.add_member/3` — or is refused
       when they belong to another Organization. An existing membership of
       this Organization, org-admin included, is left as it is. Then the
       workspace row is added, or a `:guest` row raised to `:member`; a
       `:member` row is never lowered. An optional board grant follows when
       the board still exists in that workspace; otherwise it is dropped.
    4. A **board-only invitation** grants board access only, and needs its
       board to still exist in a personal workspace. The board row is locked
       and the sender must still be the board's owner, through
       `Kanban.Workspaces.Policy`. Moving a board into an Organization
       workspace revokes its open board-only invitations
       (`Kanban.Workspaces.BoardMoves`); one an earlier move left open is
       refused here, because accepting it would grant access to an org board
       with no Organization membership, no one-Organization check and no
       `:org_member_added` audit.
    5. Board access goes through `Kanban.Boards.add_invited_user/4`, the same
       insert path and member cap as an owner's add, so a free board at its
       cap while plans are enforced refuses with `:member_cap_reached`. An
       existing board membership is left as it is, never lowered.
    6. The invitation is marked accepted.

  Every refusal rolls the whole transaction back, so a refused acceptance
  writes nothing, with one exception: when the sender may no longer send the
  invitation, it is revoked, so it cannot be used later either, and the
  refusal is the same `{:error, :invalid}` as any other. Each step that could
  fail on a database constraint is checked first, because a failed statement
  aborts the transaction.

  When the acceptance created the Organization membership, the
  `:org_member_added` audit event is recorded
  (`Kanban.Organizations.OrganizationTelemetry.org_member_added/2`). It, the
  Organization's `member_added` telemetry and the board membership
  notifications are all deferred, so they are emitted only once the
  transaction has committed. The cap-hit event is the exception: it reports a
  refusal and is emitted once, by the board path, with `via: :invitation`.

  The lock order is invitation, Organization, the user's Organization
  membership, workspace member row, board. The sender is checked under the
  Organization lock for a workspace invitation, and under the board lock for a
  board-only one, the locks an org-admin's removal, an ownership transfer and
  a board move take.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrganizationTelemetry
  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.InvitationAuthorization
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @type result :: %{
          invitation: Invitation.t(),
          workspace: Workspace.t() | nil,
          board: Board.t() | nil
        }

  @doc """
  Accepts, for `user`, the invitation found by `token_hash: hash` or
  `id: id`. Returns `{:ok, %{invitation:, workspace:, board:}}` — `workspace`
  is `nil` for a board-only invitation and `board` is `nil` when no board
  access was granted — or `{:error, :invalid}` for every refusal except a
  full free board, which is `{:error, :member_cap_reached}`.
  """
  @spec run(User.t(), [token_hash: binary()] | [id: integer()]) ::
          {:ok, result()} | {:error, :invalid | :member_cap_reached}
  def run(%User{} = user, [{key, _value}] = finder) when key in [:token_hash, :id] do
    fn -> Repo.transact(fn -> accept_locked(user, finder) end) end
    |> AfterCommit.after_commit()
    |> sender_refusal()
  end

  # A revoked invitation commits, but is refused like every other state.
  defp sender_refusal({:ok, :sender_refused}), do: {:error, :invalid}
  defp sender_refusal(result), do: result

  @doc """
  True when `user` could accept `invitation` as things stand: their email
  matches, a board-only invitation's board is still in a personal workspace,
  and a workspace invitation's workspace is not archived and they are in no
  other Organization. `invitation.workspace` must be preloaded. A
  read-only check for the accept page; acceptance checks everything again.
  """
  @spec acceptable_by?(Invitation.t(), User.t()) :: boolean()
  def acceptable_by?(%Invitation{} = invitation, %User{} = user) do
    Invitation.email_matches?(invitation, user.email) and
      target_open?(invitation) and
      not in_other_organization?(invitation, user)
  end

  defp target_open?(%Invitation{role: nil, board_id: board_id}), do: personal_board?(board_id)
  defp target_open?(%Invitation{workspace: %Workspace{archived_at: nil}}), do: true
  defp target_open?(%Invitation{}), do: false

  defp personal_board?(nil), do: false

  defp personal_board?(board_id) do
    from(b in Board,
      join: w in assoc(b, :workspace),
      where: b.id == ^board_id and w.personal == true
    )
    |> Repo.exists?()
  end

  defp in_other_organization?(%Invitation{role: nil}, _user), do: false

  defp in_other_organization?(%Invitation{workspace: %Workspace{organization_id: org_id}}, user) do
    case Organizations.get_membership(user) do
      %OrganizationMember{organization_id: ^org_id} -> false
      %OrganizationMember{} -> true
      nil -> false
    end
  end

  defp in_other_organization?(_invitation, _user), do: true

  defp accept_locked(user, finder) do
    now = DateTime.utc_now()

    with {:ok, invitation} <- lock_invitation(finder),
         {:ok, user} <- check_acceptable(invitation, user, now) do
      accept_invitation(invitation, user, now)
    end
  end

  defp accept_invitation(invitation, user, now) do
    with {:ok, result} <- apply_invitation(invitation, user),
         {:ok, invitation} <- mark_accepted(invitation, now) do
      {:ok, Map.put(result, :invitation, invitation)}
    else
      refusal -> refused(refusal)
    end
  end

  defp refused({:error, :member_cap_reached}), do: {:error, :member_cap_reached}
  defp refused({:error, {:sender_refused, invitation}}), do: revoke(invitation)
  defp refused(_refusal), do: {:error, :invalid}

  # Nothing was written before the sender check, so committing the revocation
  # commits nothing else.
  defp revoke(invitation) do
    case invitation |> Invitation.revoke_changeset(DateTime.utc_now()) |> Repo.update() do
      {:ok, _revoked} -> {:ok, :sender_refused}
      {:error, _changeset} -> {:error, :invalid}
    end
  end

  # Called with the workspace or board, and the Organization, already locked.
  defp check_sender(invitation, workspace, board) do
    if InvitationAuthorization.inviter_may_send?(invitation, workspace, board),
      do: :ok,
      else: {:error, {:sender_refused, invitation}}
  end

  defp check_acceptable(invitation, user, now) do
    if Invitation.pending?(invitation, now) and Invitation.email_matches?(invitation, user.email),
      do: fresh_user(user),
      else: {:error, :invalid}
  end

  defp mark_accepted(invitation, now),
    do: invitation |> Invitation.accept_changeset(now) |> Repo.update()

  defp lock_invitation([{key, value}]) do
    from(i in Invitation, where: field(i, ^key) == ^value, lock: "FOR UPDATE")
    |> Repo.one()
    |> case do
      %Invitation{} = invitation -> {:ok, invitation}
      nil -> {:error, :invalid}
    end
  end

  # Read again, so a stale struct for a since-disabled or unconfirmed account
  # cannot accept.
  defp fresh_user(%User{id: user_id}) do
    case Repo.get(User, user_id) do
      %User{disabled_at: nil, confirmed_at: %DateTime{}} = user -> {:ok, user}
      _disabled_unconfirmed_or_gone -> {:error, :invalid}
    end
  end

  # -- workspace invitations --------------------------------------------------

  defp apply_invitation(%Invitation{role: nil} = invitation, user),
    do: apply_board_invitation(invitation, user)

  defp apply_invitation(%Invitation{} = invitation, user),
    do: apply_workspace_invitation(invitation, user)

  defp apply_workspace_invitation(invitation, user) do
    with {:ok, workspace} <- fetch_org_workspace(invitation.workspace_id),
         :ok <- lock_and_check_sender(invitation, workspace) do
      join_and_grant(invitation, workspace, user)
    end
  end

  defp join_and_grant(invitation, workspace, user) do
    with {:ok, membership, created?} <- join_workspace(workspace, user, invitation.role),
         {:ok, board} <- grant_workspace_board(invitation, workspace, user) do
      audit_joined(created?, membership, invitation)
      {:ok, %{workspace: workspace, board: board}}
    end
  end

  # Under the Organization lock, so the sender's org-admin role cannot be
  # removed between the check and the join.
  defp lock_and_check_sender(invitation, workspace) do
    with :ok <- lock_organization(workspace.organization_id),
         do: check_sender(invitation, workspace, nil)
  end

  defp join_workspace(workspace, user, role) do
    with {:ok, membership, created?} <- join_organization(workspace.organization_id, user),
         :ok <- put_workspace_role(workspace, user, role) do
      {:ok, membership, created?}
    end
  end

  # -- board-only invitations -------------------------------------------------

  defp apply_board_invitation(invitation, user) do
    with {:ok, board, workspace} <- lock_invited_board(invitation.board_id),
         :ok <- check_sender(invitation, workspace, board) do
      board |> grant_board(user, invitation) |> board_result()
    end
  end

  # The board's workspace is read after the board lock, which a move also
  # takes, so it is the board's current one. A board no longer in a personal
  # workspace makes the sender check fail, which revokes the invitation.
  defp lock_invited_board(nil), do: {:error, :invalid}

  defp lock_invited_board(board_id) do
    from(b in Board, where: b.id == ^board_id, lock: "FOR UPDATE")
    |> Repo.one()
    |> Repo.preload(:workspace)
    |> case do
      %Board{workspace: %Workspace{} = workspace} = board -> {:ok, board, workspace}
      _gone -> {:error, :invalid}
    end
  end

  defp lock_organization(organization_id) do
    case MembershipWrites.lock_organization(organization_id) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :invalid}
    end
  end

  defp board_result({:ok, board}), do: {:ok, %{workspace: nil, board: board}}
  defp board_result(error), do: error

  defp audit_joined(true, membership, invitation),
    do: OrganizationTelemetry.org_member_added(membership, invitation.id)

  defp audit_joined(false, _membership, _invitation), do: :ok

  defp fetch_org_workspace(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{personal: false, archived_at: nil, organization_id: org_id} = workspace
      when is_integer(org_id) ->
        {:ok, workspace}

      _personal_archived_or_gone ->
        {:error, :invalid}
    end
  end

  # The caller has locked the Organization row, so no other membership write
  # to it can land between the read below and the add: `created?` is exact. A
  # membership of another Organization is refused here, before the add could
  # fail on the one-Organization unique index.
  defp join_organization(organization_id, user) do
    case Organizations.get_membership(user) do
      %OrganizationMember{organization_id: ^organization_id} = membership ->
        {:ok, membership, false}

      %OrganizationMember{} ->
        {:error, :invalid}

      nil ->
        add_membership(organization_id, user)
    end
  end

  defp add_membership(organization_id, user) do
    case Organizations.add_member(organization_id, user, :member) do
      {:ok, membership} -> {:ok, membership, true}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  # A guest invited as a member is raised to member; any other existing row is
  # kept, so an acceptance never lowers a role.
  defp put_workspace_role(%Workspace{id: workspace_id}, %User{id: user_id}, role) do
    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      nil -> WorkspaceMember.changeset(workspace_id, user_id, role) |> Repo.insert()
      %WorkspaceMember{role: :guest} = row when role == :member -> raise_to_member(row)
      %WorkspaceMember{} = row -> {:ok, row}
    end
    |> case do
      {:ok, _row} -> :ok
      {:error, _changeset} -> {:error, :invalid}
    end
  end

  defp raise_to_member(row), do: row |> WorkspaceMember.role_changeset(:member) |> Repo.update()

  # A grant whose board was deleted, or moved out of this workspace, is dropped
  # and the rest of the invitation still applies.
  defp grant_workspace_board(%Invitation{board_id: nil}, _workspace, _user), do: {:ok, nil}

  defp grant_workspace_board(%Invitation{} = invitation, %Workspace{id: workspace_id}, user) do
    case Repo.get(Board, invitation.board_id) do
      %Board{workspace_id: ^workspace_id} = board -> grant_board(board, user, invitation)
      _gone_or_moved -> {:ok, nil}
    end
  end

  # -- board access -----------------------------------------------------------

  defp grant_board(%Board{} = board, %User{} = user, %Invitation{} = invitation) do
    member_query =
      from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^user.id)

    if Repo.exists?(member_query) do
      {:ok, board}
    else
      board
      |> Boards.add_invited_user(user, invitation.board_access, inviter(invitation, user))
      |> case do
        {:ok, _board_user} -> {:ok, board}
        {:error, :member_cap_reached} -> {:error, :member_cap_reached}
        {:error, _reason} -> {:error, :invalid}
      end
    end
  end

  # The inviter is the actor of the board events (the cap event's
  # actor_user_id, the notification's "added by"); an inviter whose account
  # has since been deleted falls back to the accepting user.
  defp inviter(%Invitation{invited_by_id: nil}, user), do: user

  defp inviter(%Invitation{invited_by_id: inviter_id}, user),
    do: Repo.get(User, inviter_id) || user
end
