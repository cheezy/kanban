defmodule Kanban.Accounts.AccountDeletionTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.AccountDeletion
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @phrase "delete my account"

  defp delete(user, password \\ valid_user_password(), phrase \\ @phrase),
    do: user |> Scope.for_user() |> Accounts.delete_own_account(password, phrase)

  defp add_member(board, user, access \\ :modify) do
    Repo.insert!(%BoardUser{board_id: board.id, user_id: user.id, access: access})
  end

  defp disable_other_admins(admin) do
    from(u in User, where: u.type == :admin and u.id != ^admin.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])
  end

  defp disable_directly(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp invitation_fixture(workspace, inviter, attrs) do
    %Invitation{
      workspace_id: workspace.id,
      email: "invitee#{System.unique_integer([:positive])}@example.com",
      role: :member,
      token_hash: :crypto.strong_rand_bytes(32),
      expires_at: :second |> DateTime.utc_now() |> DateTime.add(7, :day),
      invited_by_id: inviter.id
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  describe "confirmation_phrase/0" do
    test "is the untranslated phrase the user types" do
      assert AccountDeletion.confirmation_phrase() == @phrase
      assert Accounts.account_deletion_phrase() == @phrase
    end
  end

  describe "deletion_blockers/1" do
    test "is empty for a free user with no boards" do
      assert Accounts.deletion_blockers(user_fixture()) == []
    end

    test "is empty for a user who is only a guest on someone else's board" do
      guest = user_fixture()
      add_member(board_fixture(user_fixture()), guest, :read_only)

      assert Accounts.deletion_blockers(guest) == []
    end

    test "is empty for the owner of a board only they use" do
      user = user_fixture()
      board_fixture(user)

      assert Accounts.deletion_blockers(user) == []
    end

    test "lists a personal board the user owns that others use, by name" do
      user = user_fixture()
      b_board = board_fixture(user, %{name: "B board"})
      a_board = board_fixture(user, %{name: "A board"})
      board_fixture(user, %{name: "Solo board"})
      add_member(b_board, user_fixture())
      add_member(a_board, user_fixture(), :read_only)

      assert [{:shared_board, %Board{id: first}}, {:shared_board, %Board{id: second}}] =
               Accounts.deletion_blockers(user)

      assert [first, second] == [a_board.id, b_board.id]
    end

    test "lists an org board the user owns that others use" do
      user = user_fixture()
      board = user |> board_fixture() |> move_board_to_organization(organization_fixture())
      add_member(board, user_fixture())

      assert [{:shared_board, %Board{id: id}}] = Accounts.deletion_blockers(user)
      assert id == board.id
    end

    test "a disabled other member still makes the board shared" do
      user = user_fixture()
      board = board_fixture(user)
      add_member(board, disable_directly(user_fixture()))

      assert [{:shared_board, _board}] = Accounts.deletion_blockers(user)
    end

    test "lists the last org-admin of an Organization with other members" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)

      assert [{:last_org_admin, org}] = Accounts.deletion_blockers(org_admin)
      assert org.id == organization.id
    end

    test "does not list an org-admin whose Organization has no other members" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      assert Accounts.deletion_blockers(org_admin) == []
    end

    test "does not list an org-admin when another enabled org-admin remains" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, user_fixture(), :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)

      assert Accounts.deletion_blockers(org_admin) == []
    end

    test "a disabled second org-admin does not count" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      second = user_fixture()
      organization_member_fixture(organization, second, :org_admin)
      disable_directly(second)

      assert [{:last_org_admin, _org}] = Accounts.deletion_blockers(org_admin)
    end

    test "lists the last enabled site admin, first" do
      admin = admin_fixture()

      disable_other_admins(admin)

      board = board_fixture(admin)
      add_member(board, user_fixture())

      assert [:last_site_admin, {:shared_board, _board}] = Accounts.deletion_blockers(admin)
    end

    test "does not list a site admin while another enabled admin exists" do
      admin = admin_fixture()
      admin_fixture()

      assert Accounts.deletion_blockers(admin) == []
    end
  end

  describe "delete_own_account/3 refusals" do
    test "a wrong password changes nothing" do
      user = user_fixture()

      assert {:error, :invalid_password} = delete(user, "not the password")
      assert Repo.get(User, user.id)
    end

    test "a missing password changes nothing" do
      user = user_fixture()

      assert {:error, :invalid_password} = delete(user, nil)
      assert Repo.get(User, user.id)
    end

    test "a wrong confirmation changes nothing, whatever its case or extra words" do
      user = user_fixture()

      for phrase <- ["", "DELETE MY ACCOUNT", "delete my account now", "delete", nil] do
        assert {:error, :invalid_confirmation} = delete(user, valid_user_password(), phrase)
      end

      assert Repo.get(User, user.id)
    end

    test "surrounding whitespace in the confirmation is accepted" do
      user = user_fixture()

      assert {:ok, _} = delete(user, valid_user_password(), "  delete my account \n")
    end

    test "a blocked user gets the blockers and keeps everything" do
      user = user_fixture()
      board = board_fixture(user)
      add_member(board, user_fixture())

      assert {:error, {:blocked, [{:shared_board, %Board{id: id}}]}} = delete(user)
      assert id == board.id
      assert Repo.get(User, user.id)
      assert Repo.get(Board, board.id)
    end

    test "the last org-admin of an Organization with members is refused" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)

      assert {:error, {:blocked, [{:last_org_admin, _org}]}} = delete(org_admin)
      assert Repo.get(User, org_admin.id)
    end

    test "the last enabled site admin cannot delete themselves" do
      admin = admin_fixture()

      disable_other_admins(admin)

      assert {:error, {:blocked, [:last_site_admin]}} = delete(admin)
      assert Repo.get(User, admin.id)
    end

    test "a site admin can delete themselves while another enabled admin remains" do
      admin = admin_fixture()
      admin_fixture()

      assert {:ok, _} = delete(admin)
    end

    test "a deleted or disabled account is not found" do
      user = user_fixture()
      assert {:ok, _} = delete(user)
      assert {:error, :not_found} = delete(user)

      disabled = disable_directly(user_fixture())
      assert {:error, :not_found} = delete(disabled)
    end

    test "a scope without a user is not found" do
      assert {:error, :not_found} =
               AccountDeletion.delete_own_account(nil, valid_user_password(), @phrase)
    end
  end

  describe "delete_own_account/3 success" do
    setup do
      user = user_fixture()
      %{user: user, workspace: Workspaces.get_personal_workspace(user)}
    end

    test "removes the user, their tokens, memberships and personal workspace", %{
      user: user,
      workspace: workspace
    } do
      own_board = board_fixture(user)
      {:ok, {own_token, _plain}} = ApiTokens.create_api_token(user, own_board, %{name: "mine"})

      other_board = board_fixture(user_fixture())
      add_member(other_board, user)

      {:ok, {other_token, _plain}} =
        ApiTokens.create_api_token(user, other_board, %{name: "theirs"})

      organization = organization_fixture()
      organization_member_fixture(organization, user, :member)
      org_workspace = org_workspace_fixture(organization)
      workspace_member_fixture(org_workspace, user)

      session_token = Accounts.generate_user_session_token(user)

      assert {:ok, %{user: %User{id: id}, session_tokens: [%UserToken{context: "session"}]}} =
               delete(user)

      assert id == user.id
      refute Repo.get(User, user.id)
      refute Accounts.get_user_by_session_token(session_token)
      refute from(t in UserToken, where: t.user_id == ^user.id) |> Repo.exists?()
      refute Repo.get(ApiToken, own_token.id)
      refute Repo.get(ApiToken, other_token.id)
      refute from(bu in BoardUser, where: bu.user_id == ^user.id) |> Repo.exists?()
      refute from(m in OrganizationMember, where: m.user_id == ^user.id) |> Repo.exists?()
      refute from(m in WorkspaceMember, where: m.user_id == ^user.id) |> Repo.exists?()
      refute Repo.get(Workspace, workspace.id)
      refute Repo.get(Board, own_board.id)
      assert Repo.get(Board, other_board.id)
      assert Repo.get(Workspace, org_workspace.id)
    end

    test "deletes a board only they use with its columns and tasks", %{user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert {:ok, _} = delete(user)

      refute Repo.get(Board, board.id)
      refute Repo.get(Column, column.id)
      refute Repo.get(Task, task.id)
    end

    test "keeps tasks they created on boards others use, with attribution nilified", %{
      user: user
    } do
      other = user_fixture()
      board = board_fixture(other)
      add_member(board, user)
      column = column_fixture(board)
      task = task_fixture(column, %{created_by_id: user.id})

      from(t in Task, where: t.id == ^task.id)
      |> Repo.update_all(set: [created_by_id: user.id, assigned_to_id: user.id])

      assert {:ok, _} = delete(user)

      kept = Repo.get!(Task, task.id)
      assert kept.created_by_id == nil
      assert kept.assigned_to_id == nil
    end

    test "re-homes a board others use from their personal workspace to its owner", %{
      user: user,
      workspace: workspace
    } do
      board = place_board_in_workspace(workspace)

      [%BoardUser{user_id: owner_id}] =
        from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.all()

      owner = Repo.get!(User, owner_id)

      assert {:ok, _} = delete(user)

      assert Repo.get!(Board, board.id).workspace_id ==
               Workspaces.get_personal_workspace(owner).id
    end

    test "re-homes an ownerless board to its earliest remaining member", %{
      user: user,
      workspace: workspace
    } do
      board = place_board_in_workspace(workspace)
      from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()

      earliest = user_fixture() |> remove_personal_workspace()
      later = user_fixture()
      add_member(board, user)
      add_member(board, earliest)
      add_member(board, later)

      assert {:ok, _} = delete(user)

      home = Workspaces.get_personal_workspace(earliest)
      assert %Workspace{personal: true} = home
      assert Repo.get!(Board, board.id).workspace_id == home.id
    end

    test "re-homes a memberless board to another enabled site admin", %{
      user: user,
      workspace: workspace
    } do
      board = place_board_in_workspace(workspace)
      from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()
      admin_fixture()

      assert {:ok, _} = delete(user)

      moved = Repo.get!(Board, board.id)
      refute moved.workspace_id == workspace.id
      assert Repo.get!(Workspace, moved.workspace_id).personal
    end

    test "makes the site admin the owner of a board whose other members are all disabled", %{
      user: user,
      workspace: workspace
    } do
      board = place_board_in_workspace(workspace)
      from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()
      add_member(board, user)
      old_owner = disable_directly(user_fixture())
      add_member(board, old_owner, :owner)
      admin = admin_fixture()

      assert {:ok, _} = delete(user)

      assert Repo.get!(Board, board.id).workspace_id ==
               Workspaces.get_personal_workspace(admin).id

      assert Boards.get_user_access(board.id, admin.id) == :owner
      assert Boards.get_user_access(board.id, old_owner.id) == :modify
      assert [event] = AuditLog.list_events(action: :board_given_to_site_admin)
      assert event.metadata["board_id"] == board.id
      assert event.metadata["member_user_id"] == admin.id
    end

    test "deletes a memberless board when no other enabled site admin exists", %{
      user: user,
      workspace: workspace
    } do
      board = place_board_in_workspace(workspace)
      from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()
      refute from(u in User, where: u.type == :admin and is_nil(u.disabled_at)) |> Repo.exists?()

      assert {:ok, _} = delete(user)

      refute Repo.get(Board, board.id)
    end

    test "leaves an org board they alone used in its workspace", %{user: user} do
      board = user |> board_fixture() |> move_board_to_organization(organization_fixture())

      assert {:ok, _} = delete(user)

      assert Repo.get!(Board, board.id).workspace_id == board.workspace_id
    end

    test "revokes their open sent invitations and leaves accepted ones", %{user: user} do
      organization = organization_fixture()
      org_workspace = org_workspace_fixture(organization)
      open = invitation_fixture(org_workspace, user, %{})

      accepted =
        invitation_fixture(org_workspace, user, %{accepted_at: DateTime.utc_now(:second)})

      assert {:ok, _} = delete(user)

      open = Repo.get!(Invitation, open.id)
      assert %DateTime{} = open.revoked_at
      assert open.invited_by_id == nil
      assert Repo.get!(Invitation, accepted.id).revoked_at == nil
    end

    test "keeps invitations they received, unlinked from the deleted account", %{user: user} do
      org_workspace = org_workspace_fixture(organization_fixture())
      inviter = user_fixture()

      registered =
        invitation_fixture(org_workspace, inviter, %{
          email: user.email,
          registered_user_id: user.id,
          accepted_at: DateTime.utc_now(:second)
        })

      open = invitation_fixture(org_workspace, inviter, %{email: user.email})

      assert {:ok, _} = delete(user)

      assert Repo.get!(Invitation, registered.id).registered_user_id == nil
      open = Repo.get!(Invitation, open.id)
      assert open.revoked_at == nil
      assert open.invited_by_id == inviter.id
    end

    test "records the audit event with the user id and no email", %{user: user} do
      attach_telemetry([[:kanban, :audit, :account_self_deleted]])
      user_id = user.id

      assert {:ok, _} = delete(user)

      assert_received {:telemetry_event, [:kanban, :audit, :account_self_deleted], _,
                       %{user_id: ^user_id} = metadata}

      refute Map.has_key?(metadata, :email)

      assert [event] = AuditLog.list_events(action: :account_self_deleted)
      assert event.metadata["user_id"] == user.id
      refute inspect(event.metadata) =~ user.email
    end

    test "broadcasts a members change for the boards they were on", %{user: user} do
      board = board_fixture(user_fixture())
      add_member(board, user)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      board_id = board.id

      assert {:ok, _} = delete(user)

      assert_received {Kanban.Boards, :members_changed, ^board_id}
    end

    test "a former owner can delete after transferring, and the board stays with the new owner",
         %{user: user} do
      board = board_fixture(user)
      new_owner = user_fixture()
      add_member(board, new_owner)

      assert {:error, {:blocked, _}} = delete(user)
      assert {:ok, _} = Boards.transfer_board_ownership(board, new_owner, user)
      assert {:ok, _} = delete(user)

      kept = Repo.get!(Board, board.id)
      assert kept.workspace_id == Workspaces.get_personal_workspace(new_owner).id
      assert Boards.owner?(kept, new_owner)
    end

    test "a user without a personal workspace can delete their account", %{user: user} do
      remove_personal_workspace(user)

      assert {:ok, _} = delete(user)
      refute Repo.get(User, user.id)
    end

    test "a free user with no Organization can delete their account", %{user: user} do
      refute Kanban.Organizations.get_membership(user)
      assert {:ok, _} = delete(user)
    end
  end

  describe "deletion_warnings/1" do
    test "warns the only member of an Organization, in either role, without blocking" do
      for role <- [:org_admin, :member] do
        user = user_fixture()
        organization = organization_fixture()
        organization_member_fixture(organization, user, role)

        assert [{:sole_org_member, warned}] = AccountDeletion.deletion_warnings(user)
        assert warned.id == organization.id
        assert AccountDeletion.deletion_blockers(user) == []
      end
    end

    test "is empty with other members, and without an Organization" do
      user = user_fixture()
      assert AccountDeletion.deletion_warnings(user) == []

      organization = organization_fixture()
      organization_member_fixture(organization, user, :org_admin)
      organization_member_fixture(organization, user_fixture(), :org_admin)

      assert AccountDeletion.deletion_warnings(user) == []
    end

    test "the sole member can still delete, leaving the Organization and its workspace" do
      user = user_fixture()
      organization = organization_fixture()
      organization_member_fixture(organization, user, :org_admin)
      workspace = org_workspace_fixture(organization)

      assert {:ok, _} = delete(user)
      assert Repo.get(Workspace, workspace.id)

      refute from(m in OrganizationMember, where: m.organization_id == ^organization.id)
             |> Repo.exists?()
    end
  end

  describe "delete_own_account/3 cleanup of work in flight" do
    test "archives the delivery targets they own and no one else's" do
      user = user_fixture()
      other = user_fixture()
      date = Date.add(Date.utc_today(), 30)

      target = fn owner, name ->
        owner |> Scope.for_user() |> Targets.create_target(%{name: name, target_date: date})
      end

      {:ok, mine} = target.(user, "Mine")
      {:ok, theirs} = target.(other, "Theirs")
      archived_at = ~U[2026-01-01 00:00:00.000000Z]
      {:ok, old} = target.(user, "Old")
      old |> Ecto.Changeset.change(archived_at: archived_at) |> Repo.update!()

      assert {:ok, _} = delete(user)

      assert %DeliveryTarget{archived_at: %DateTime{}, owner_id: nil} =
               Repo.get!(DeliveryTarget, mine.id)

      assert %DeliveryTarget{archived_at: nil} = Repo.get!(DeliveryTarget, theirs.id)
      assert Repo.get!(DeliveryTarget, old.id).archived_at == archived_at
    end

    test "returns the tasks they claimed on other people's boards to Ready" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user_fixture())
      add_member(board, user)
      columns = Kanban.Columns.list_columns(board)
      doing = Enum.find(columns, &(&1.name == "Doing"))
      ready = Enum.find(columns, &(&1.name == "Ready"))
      now = DateTime.utc_now(:second)

      task =
        doing
        |> task_fixture()
        |> Ecto.Changeset.change(
          status: :in_progress,
          claimed_at: now,
          claim_expires_at: DateTime.add(now, 3600),
          assigned_to_id: user.id
        )
        |> Repo.update!()

      assert {:ok, _} = delete(user)

      assert %Task{status: :open, assigned_to_id: nil, claimed_at: nil, column_id: column_id} =
               Repo.get!(Task, task.id)

      assert column_id == ready.id
    end
  end

  describe "delete_disabled_managed_account/1" do
    defp disabled_managed(user) do
      user
      |> User.managed_by_changeset(organization_fixture().id)
      |> Repo.update!()
      |> disable_directly()
    end

    test "deletes a disabled managed account with the self-deletion cascade" do
      user = disabled_managed(user_fixture())
      board = board_fixture(user)

      assert {:ok, %User{id: id}} = AccountDeletion.delete_disabled_managed_account(user)

      assert id == user.id
      refute Repo.get(User, user.id)
      refute Repo.get(Board, board.id)
      refute Workspaces.get_personal_workspace(user)
      assert AuditLog.list_events(action: :account_self_deleted) == []
    end

    test "is refused while the account owns a board other people use" do
      user = disabled_managed(user_fixture())
      board = board_fixture(user)
      add_member(board, user_fixture())

      assert {:error, {:blocked, [{:shared_board, %Board{id: id}}]}} =
               AccountDeletion.delete_disabled_managed_account(user)

      assert id == board.id
      assert Repo.get(User, user.id)
    end

    test "refuses an enabled managed account and a disabled unmanaged one" do
      enabled =
        user_fixture() |> User.managed_by_changeset(organization_fixture().id) |> Repo.update!()

      unmanaged = disable_directly(user_fixture())

      for user <- [enabled, unmanaged] do
        refute AccountDeletion.disabled_managed?(user)
        assert {:error, :not_found} = AccountDeletion.delete_disabled_managed_account(user)
        assert Repo.get(User, user.id)
      end
    end

    # The struct passed in is stale: the row was re-enabled after it was read.
    test "re-checks the account's state under the lock" do
      user = disabled_managed(user_fixture())
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [disabled_at: nil])

      assert AccountDeletion.disabled_managed?(user)
      assert {:error, :not_found} = AccountDeletion.delete_disabled_managed_account(user)
      assert Repo.get(User, user.id)
    end
  end
end
