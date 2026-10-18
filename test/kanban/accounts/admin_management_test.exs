defmodule Kanban.Accounts.AdminManagementTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Ecto.Query
  import ExUnit.CaptureLog
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  # disable_user/2 requires the actor to be a *different* enabled admin, who then
  # remains enabled — so the API can never leave the system with only one enabled
  # admin. That is the guard working, but it means the states below (a lone
  # enabled admin, no enabled admin at all) have to be built directly.
  defp disable_directly(user) do
    user
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  describe "list_users/0" do
    test "returns all users" do
      user_one = user_fixture()
      user_two = user_fixture()

      ids = Enum.map(Accounts.list_users(), & &1.id)

      assert user_one.id in ids
      assert user_two.id in ids
    end

    test "returns users in a stable order by email" do
      charlie = user_fixture(%{email: "charlie@example.com"})
      alice = user_fixture(%{email: "alice@example.com"})
      bob = user_fixture(%{email: "bob@example.com"})

      emails = Enum.map(Accounts.list_users(), & &1.email)

      assert emails == Enum.sort(emails)
      assert [alice.email, bob.email, charlie.email] == emails
    end

    test "includes disabled users" do
      user = user_fixture()
      {:ok, _disabled} = Accounts.disable_user(user, admin_fixture())

      assert user.id in Enum.map(Accounts.list_users(), & &1.id)
    end
  end

  describe "disable_user/2" do
    test "sets disabled_at to the current UTC time and returns {:ok, user}" do
      user = user_fixture()
      assert user.disabled_at == nil

      assert {:ok, %User{disabled_at: %DateTime{} = disabled_at}} =
               Accounts.disable_user(user, admin_fixture())

      assert DateTime.diff(DateTime.utc_now(), disabled_at) <= 1
    end

    test "returns {:error, :unauthorized} when the acting user is not an admin" do
      user = user_fixture()
      acting_user = user_fixture()

      assert {:error, :unauthorized} = Accounts.disable_user(user, acting_user)
      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    test "returns {:error, :unauthorized} when the acting admin is disabled" do
      user = user_fixture()
      acting_admin = disable_directly(admin_fixture())

      assert {:error, :unauthorized} = Accounts.disable_user(user, acting_admin)
      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    # This is the lockout vector the guard exists for: a lone admin disabling
    # themselves would leave nobody able to sign in and re-enable anyone.
    test "returns {:error, :cannot_disable_self} when the target is the acting user" do
      admin = admin_fixture()

      assert {:error, :cannot_disable_self} = Accounts.disable_user(admin, admin)
      assert Accounts.get_user!(admin.id).disabled_at == nil
    end

    test "returns {:error, :last_admin} when the target is the only enabled admin" do
      target_admin = admin_fixture()
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.disable_user(target_admin, stale_acting_admin)
      assert Accounts.get_user!(target_admin.id).disabled_at == nil
    end

    test "allows disabling an admin when another enabled admin remains" do
      target_admin = admin_fixture()
      acting_admin = admin_fixture()

      assert {:ok, %User{disabled_at: %DateTime{}}} =
               Accounts.disable_user(target_admin, acting_admin)
    end

    test "checks the unauthorized guard before the self guard" do
      user = user_fixture()

      assert {:error, :unauthorized} = Accounts.disable_user(user, user)
    end

    test "persists disabled_at to the database" do
      user = user_fixture()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      assert Accounts.get_user!(user.id).disabled_at != nil
    end

    test "truncates disabled_at to second precision" do
      user = user_fixture()

      assert {:ok, %User{disabled_at: disabled_at}} = Accounts.disable_user(user, admin_fixture())
      assert disabled_at.microsecond == {0, 0}
    end

    test "is idempotent when the user is already disabled" do
      user = user_fixture()

      assert {:ok, once} = Accounts.disable_user(user, admin_fixture())
      assert {:ok, twice} = Accounts.disable_user(once, admin_fixture())
      assert twice.disabled_at != nil
    end

    test "does not clear confirmed_at or change the user type" do
      admin = admin_fixture()

      assert {:ok, disabled} = Accounts.disable_user(admin, admin_fixture())
      assert disabled.confirmed_at == admin.confirmed_at
      assert disabled.type == :admin
    end
  end

  describe "enable_user/2" do
    test "clears disabled_at to nil and returns {:ok, user}" do
      user = user_fixture()
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      assert disabled.disabled_at != nil

      assert {:ok, %User{disabled_at: nil}} = Accounts.enable_user(disabled, admin_fixture())
    end

    test "persists nil to the database" do
      user = user_fixture()
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Accounts.enable_user(disabled, admin_fixture())

      assert Accounts.get_user!(user.id).disabled_at == nil
    end

    test "is a no-op for an already-enabled user" do
      user = user_fixture()

      assert {:ok, %User{disabled_at: nil}} = Accounts.enable_user(user, admin_fixture())
    end

    test "returns {:error, :unauthorized} when the acting user is not an admin (D156)" do
      user = user_fixture()
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      acting_user = user_fixture()

      assert {:error, :unauthorized} = Accounts.enable_user(disabled, acting_user)
      assert Accounts.get_user!(user.id).disabled_at != nil
    end

    test "returns {:error, :unauthorized} when the acting admin is disabled (D156)" do
      user = user_fixture()
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      acting_admin = disable_directly(admin_fixture())

      assert {:error, :unauthorized} = Accounts.enable_user(disabled, acting_admin)
      assert Accounts.get_user!(user.id).disabled_at != nil
    end
  end

  describe "delete_user/2" do
    test "deletes the user and returns {:ok, user} when all guards pass" do
      user = user_fixture()
      admin = admin_fixture()

      assert {:ok, %User{}} = Accounts.delete_user(user, admin)
      assert Repo.get(User, user.id) == nil
    end

    # The users_tokens FK is `on_delete: :delete_all`, so Postgres would cascade
    # these away regardless. This asserts the end state, not the explicit
    # Repo.delete_all — it passes with or without it.
    test "removes the user's tokens" do
      user = user_fixture()
      admin = admin_fixture()
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_user_session_token(user)
      assert Repo.all_by(UserToken, user_id: user.id) != []

      assert {:ok, _} = Accounts.delete_user(user, admin)
      assert Repo.all_by(UserToken, user_id: user.id) == []
    end

    test "returns {:error, :unauthorized} when the acting user is not an admin" do
      user = user_fixture()
      acting_user = user_fixture()

      assert {:error, :unauthorized} = Accounts.delete_user(user, acting_user)
      assert Repo.get(User, user.id) != nil
    end

    test "returns {:error, :unauthorized} when the acting admin is disabled" do
      user = user_fixture()
      acting_admin = disable_directly(admin_fixture())

      assert {:error, :unauthorized} = Accounts.delete_user(user, acting_admin)
      assert Repo.get(User, user.id) != nil
    end

    test "returns {:error, :cannot_delete_self} when the target is the acting user" do
      admin = admin_fixture()

      assert {:error, :cannot_delete_self} = Accounts.delete_user(admin, admin)
      assert Repo.get(User, admin.id) != nil
    end

    test "returns {:error, :user_has_boards} when the user belongs to a board" do
      user = user_fixture()
      admin = admin_fixture()
      _board = board_fixture(user)

      assert {:error, :user_has_boards} = Accounts.delete_user(user, admin)
      assert Repo.get(User, user.id) != nil
    end

    # An enabled acting admin can never trip the last_admin guard — they would
    # themselves be a second enabled admin. The guard is reachable only through
    # a stale actor struct: one loaded before the acting admin was disabled, as
    # a live session would hold. The authorization guard reads the struct in
    # memory; last_admin? reads the database.
    test "returns {:error, :last_admin} when the target is the only enabled admin" do
      target_admin = admin_fixture()
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.delete_user(target_admin, stale_acting_admin)
      assert Repo.get(User, target_admin.id) != nil
    end

    # Regression: a disabled admin must still be guarded. Deleting the last
    # admin row leaves nobody who can be promoted, even though that admin was
    # already unable to sign in.
    test "returns {:error, :last_admin} when the target is a disabled admin and no enabled admin remains" do
      target_admin = disable_directly(admin_fixture())
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.delete_user(target_admin, stale_acting_admin)
      assert Repo.get(User, target_admin.id) != nil
    end

    test "allows deleting an admin when another enabled admin remains" do
      target_admin = admin_fixture()
      _other_admin = admin_fixture()
      acting_admin = admin_fixture()

      assert {:ok, _} = Accounts.delete_user(target_admin, acting_admin)
      assert Repo.get(User, target_admin.id) == nil
    end

    test "allows deleting a disabled admin when an enabled admin remains" do
      disabled_admin = disable_directly(admin_fixture())
      acting_admin = admin_fixture()

      assert {:ok, _} = Accounts.delete_user(disabled_admin, acting_admin)
      assert Repo.get(User, disabled_admin.id) == nil
    end

    test "checks the unauthorized guard before the self guard" do
      user = user_fixture()

      assert {:error, :unauthorized} = Accounts.delete_user(user, user)
    end

    test "checks the self guard before the has_boards guard" do
      admin = admin_fixture()
      _board = board_fixture(admin)

      assert {:error, :cannot_delete_self} = Accounts.delete_user(admin, admin)
    end

    test "checks the has_boards guard before the last_admin guard" do
      target_admin = admin_fixture()
      _board = board_fixture(target_admin)
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :user_has_boards} = Accounts.delete_user(target_admin, stale_acting_admin)
    end

    test "checks the last_admin guard before the personal workspace's boards" do
      target_admin = admin_fixture()
      _board = place_board_in_personal_workspace(target_admin)
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.delete_user(target_admin, stale_acting_admin)
    end
  end

  # A board in `user`'s personal workspace with no board_users row for them.
  defp place_board_in_personal_workspace(user) do
    user |> Workspaces.get_personal_workspace() |> place_board_in_workspace()
  end

  defp personal_workspace_count do
    Workspace |> where([w], w.personal) |> Repo.aggregate(:count)
  end

  describe "delete_user/2 and the personal workspace" do
    test "deletes the user's empty personal workspace and its owner row in the same transaction" do
      user = user_fixture()
      admin = admin_fixture()
      workspace = personal_workspace_fixture(user)
      before = personal_workspace_count()

      assert {:ok, %User{}} = Accounts.delete_user(user, admin)
      assert personal_workspace_count() == before - 1
      assert Repo.get(Workspace, workspace.id) == nil
      refute WorkspaceMember |> where([m], m.workspace_id == ^workspace.id) |> Repo.exists?()
    end

    test "returns {:error, :personal_workspace_has_boards} and deletes nothing when a board sits in the user's personal workspace without a board_users row" do
      user = user_fixture()
      admin = admin_fixture()
      _ = Accounts.generate_user_session_token(user)
      board = place_board_in_personal_workspace(user)
      workspace = Workspaces.get_personal_workspace(user)

      refute Boards.user_has_boards?(user)

      assert {:error, :personal_workspace_has_boards} = Accounts.delete_user(user, admin)
      assert Repo.get(User, user.id)
      assert Repo.all_by(UserToken, user_id: user.id) != []
      assert Repo.get(Workspace, workspace.id)
      assert Workspaces.get_member_role(workspace, user) == :owner
      assert Repo.get!(Board, board.id).workspace_id == workspace.id
    end

    test "emits no deletion telemetry when the personal workspace refuses" do
      user = user_fixture()
      admin = admin_fixture()
      _board = place_board_in_personal_workspace(user)
      attach_telemetry([[:kanban, :user, :deleted]])

      assert {:error, :personal_workspace_has_boards} = Accounts.delete_user(user, admin)
      refute_received {:telemetry_event, [:kanban, :user, :deleted], _, _}
    end

    test "still succeeds for a user who has no personal workspace at all" do
      user = remove_personal_workspace(user_fixture())
      admin = admin_fixture()

      assert {:ok, %User{}} = Accounts.delete_user(user, admin)
      assert Repo.get(User, user.id) == nil
    end

    test "deletes only the user's own personal workspace, never an org workspace they belong to" do
      admin = admin_fixture()
      organization = organization_fixture()
      user = user_fixture()
      organization_member_fixture(organization, user, :member)
      org_workspace = org_workspace_fixture(organization)
      workspace_member_fixture(org_workspace, user, :guest)
      other = user_fixture()
      others = personal_workspace_fixture(other)

      assert {:ok, _} = Accounts.delete_user(user, admin)
      assert Repo.get(Workspace, org_workspace.id)
      assert Repo.get(Workspace, others.id)
      refute WorkspaceMember |> where([m], m.user_id == ^user.id) |> Repo.exists?()
    end

    test "keeps the existing refusals, none of which touches the personal workspace" do
      admin = admin_fixture()
      owner = user_fixture()
      _board = board_fixture(owner)
      owner_workspace = Workspaces.get_personal_workspace(owner)

      assert {:error, :unauthorized} = Accounts.delete_user(owner, user_fixture())
      assert {:error, :cannot_delete_self} = Accounts.delete_user(admin, admin)
      assert {:error, :user_has_boards} = Accounts.delete_user(owner, admin)

      assert Repo.get(Workspace, owner_workspace.id)
      assert Workspaces.get_personal_workspace(admin)
    end

    test "keeps the target's empty personal workspace when the last_admin guard refuses" do
      target_admin = admin_fixture()
      workspace = Workspaces.get_personal_workspace(target_admin)
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.delete_user(target_admin, stale_acting_admin)
      assert Repo.get(Workspace, workspace.id)
      assert Workspaces.get_member_role(workspace, target_admin) == :owner
    end
  end

  describe "disabled_at is not settable through user-facing changesets" do
    test "registration_changeset ignores disabled_at" do
      attrs = valid_user_attributes(%{disabled_at: DateTime.utc_now(:second)})
      {:ok, user} = Accounts.register_user(attrs)

      assert user.disabled_at == nil
    end

    test "email_changeset ignores disabled_at" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      changeset =
        User.email_changeset(user, %{email: unique_user_email(), disabled_at: now})

      refute Map.has_key?(changeset.changes, :disabled_at)
    end

    test "name_changeset ignores disabled_at" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      changeset = User.name_changeset(user, %{name: "New Name", disabled_at: now})

      refute Map.has_key?(changeset.changes, :disabled_at)
    end

    test "password_changeset ignores disabled_at" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      changeset =
        User.password_changeset(user, %{
          password: valid_user_password(),
          disabled_at: now
        })

      refute Map.has_key?(changeset.changes, :disabled_at)
    end
  end

  describe "user administration telemetry" do
    @admin_events [
      [:kanban, :user, :disabled],
      [:kanban, :user, :enabled],
      [:kanban, :user, :deleted]
    ]

    test "disable_user emits disabled" do
      user = user_fixture()
      admin = admin_fixture()
      attach_telemetry(@admin_events)

      assert {:ok, disabled} = Accounts.disable_user(user, admin)

      assert_received {:telemetry_event, [:kanban, :user, :disabled], %{count: 1}, metadata}
      assert metadata == %{user_id: user.id, actor_user_id: admin.id}

      assert {:ok, _again} = Accounts.disable_user(disabled, admin)
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "a refused disable emits nothing" do
      user = user_fixture()
      admin = admin_fixture()
      attach_telemetry(@admin_events)

      assert {:error, :unauthorized} = Accounts.disable_user(user, user_fixture())
      assert {:error, :cannot_disable_self} = Accounts.disable_user(admin, admin)
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "enable_user emits enabled with the administrator as actor" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, disabled} = Accounts.disable_user(user, admin)
      attach_telemetry(@admin_events)

      assert {:ok, enabled} = Accounts.enable_user(disabled, admin)

      assert_received {:telemetry_event, [:kanban, :user, :enabled], %{count: 1}, metadata}
      assert metadata == %{user_id: user.id, actor_user_id: admin.id}

      assert {:ok, _still_enabled} = Accounts.enable_user(enabled, admin)
      assert {:error, :unauthorized} = Accounts.enable_user(disabled, user_fixture())
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "delete_user emits deleted with the deleted user's id" do
      user = user_fixture()
      admin = admin_fixture()
      attach_telemetry(@admin_events)

      assert {:ok, _deleted} = Accounts.delete_user(user, admin)

      assert_received {:telemetry_event, [:kanban, :user, :deleted], %{count: 1}, metadata}
      assert metadata == %{user_id: user.id, actor_user_id: admin.id}
    end

    test "a refused delete emits nothing" do
      user = user_fixture()
      admin = admin_fixture()
      _board = board_fixture(user)
      attach_telemetry(@admin_events)

      assert {:error, :user_has_boards} = Accounts.delete_user(user, admin)
      assert {:error, :cannot_delete_self} = Accounts.delete_user(admin, admin)
      assert {:error, :unauthorized} = Accounts.delete_user(admin, user_fixture())
      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end
  end

  describe "delete_user/2 audit events" do
    defp refusals do
      AuditLog.list_events(action: :user_delete_refused)
    end

    defp deletions do
      AuditLog.list_events(action: :user_deleted)
    end

    # One refusal row naming `reason`, the actor and the target, and no deletion.
    defp assert_refusal_recorded(reason, actor, target) do
      assert [event] = refusals()
      assert event.actor_user_id == actor.id
      assert event.metadata["user_id"] == actor.id
      assert event.metadata["member_user_id"] == target.id
      assert event.metadata["reason"] == Atom.to_string(reason)
      assert deletions() == []
    end

    test "a successful delete records a user_deleted audit event" do
      user = user_fixture()
      admin = admin_fixture()

      assert {:ok, _deleted} = Accounts.delete_user(user, admin)

      assert [event] = deletions()
      assert event.actor_user_id == admin.id
      assert event.metadata["user_id"] == admin.id
      assert event.metadata["member_user_id"] == user.id
      assert refusals() == []
    end

    test "refusing an actor who is not an admin records user_delete_refused" do
      user = user_fixture()
      acting_user = user_fixture()

      assert {:error, :unauthorized} = Accounts.delete_user(user, acting_user)
      assert_refusal_recorded(:unauthorized, acting_user, user)
    end

    test "refusing a disabled admin records user_delete_refused" do
      user = user_fixture()
      acting_admin = disable_directly(admin_fixture())

      assert {:error, :unauthorized} = Accounts.delete_user(user, acting_admin)
      assert_refusal_recorded(:unauthorized, acting_admin, user)
    end

    test "refusing a self-delete records user_delete_refused" do
      admin = admin_fixture()

      assert {:error, :cannot_delete_self} = Accounts.delete_user(admin, admin)
      assert_refusal_recorded(:cannot_delete_self, admin, admin)
    end

    test "refusing a user who belongs to a board records user_delete_refused" do
      user = user_fixture()
      admin = admin_fixture()
      _board = board_fixture(user)

      assert {:error, :user_has_boards} = Accounts.delete_user(user, admin)
      assert_refusal_recorded(:user_has_boards, admin, user)
    end

    test "refusing the last admin records user_delete_refused" do
      target_admin = admin_fixture()
      stale_acting_admin = admin_fixture()
      _ = disable_directly(stale_acting_admin)

      assert {:error, :last_admin} = Accounts.delete_user(target_admin, stale_acting_admin)
      assert_refusal_recorded(:last_admin, stale_acting_admin, target_admin)
    end

    test "a refusal inside the transaction is still audited" do
      user = user_fixture()
      admin = admin_fixture()
      _board = place_board_in_personal_workspace(user)

      assert {:error, :personal_workspace_has_boards} = Accounts.delete_user(user, admin)
      assert Repo.get(User, user.id)
      assert_refusal_recorded(:personal_workspace_has_boards, admin, user)
    end

    test "the audit metadata holds ids only" do
      user = user_fixture(%{name: "Audit Target Person"})
      boarded = user_fixture(%{name: "Audit Boarded Person"})
      _board = board_fixture(boarded)
      admin = admin_fixture()

      assert {:ok, _deleted} = Accounts.delete_user(user, admin)
      assert {:error, :user_has_boards} = Accounts.delete_user(boarded, admin)

      assert [deleted] = deletions()
      assert deleted.metadata |> Map.keys() |> Enum.sort() == ["member_user_id", "user_id"]

      assert [refused] = refusals()

      assert refused.metadata |> Map.keys() |> Enum.sort() ==
               ["member_user_id", "reason", "user_id"]

      for {event, target} <- [{deleted, user}, {refused, boarded}] do
        stored = Jason.encode!(event.metadata)
        refute stored =~ target.email
        refute stored =~ target.name
      end
    end

    test "an audit write failure never turns a successful delete into an error" do
      user = user_fixture()
      admin = admin_fixture()

      Repo.transact(fn ->
        # Poison the transaction so the audit insert cannot succeed.
        assert {:error, _} = Repo.query("SELECT 1 / 0")

        log =
          capture_log([level: :error], fn ->
            assert {:ok, ^user} = UserTelemetry.deleted({:ok, user}, user, admin)
          end)

        assert log =~ "security_audit_persist_failed"
        {:error, :done}
      end)

      assert deletions() == []
    end

    test "a changeset error passes through and records nothing" do
      user = user_fixture()
      admin = admin_fixture()
      result = {:error, Ecto.Changeset.change(user)}

      assert UserTelemetry.deleted(result, user, admin) == result
      assert deletions() == []
      assert refusals() == []
    end

    test "a deleted user's own earlier audit rows survive with no actor link" do
      user = user_fixture()
      admin = admin_fixture()
      :ok = AuditLog.event(:two_factor_enabled, user_id: user.id)

      assert {:ok, _deleted} = Accounts.delete_user(user, admin)

      assert [event] = AuditLog.list_events(action: :two_factor_enabled)
      assert event.actor_user_id == nil
      assert event.actor_user == nil
      assert event.metadata["user_id"] == user.id
    end
  end
end
