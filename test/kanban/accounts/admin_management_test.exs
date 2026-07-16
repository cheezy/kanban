defmodule Kanban.Accounts.AdminManagementTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken

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
end
