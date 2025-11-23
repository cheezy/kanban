defmodule Kanban.Accounts.UserTypeTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User

  describe "user type field" do
    test "new users default to :user type" do
      user = user_fixture()
      assert user.type == :user
    end

    test "user type is stored in the database" do
      user = user_fixture()
      reloaded_user = Accounts.get_user!(user.id)
      assert reloaded_user.type == :user
    end

    test "registration does not allow setting type" do
      attrs = valid_user_attributes(%{type: :admin})
      {:ok, user} = Accounts.register_user(attrs)

      assert user.type == :user
    end
  end

  describe "update_user_type/2" do
    test "updates user type to admin" do
      user = user_fixture()
      assert user.type == :user

      {:ok, updated_user} = Accounts.update_user_type(user, :admin)
      assert updated_user.type == :admin
    end

    test "updates admin type back to user" do
      user = user_fixture()
      {:ok, admin} = Accounts.update_user_type(user, :admin)
      assert admin.type == :admin

      {:ok, regular_user} = Accounts.update_user_type(admin, :user)
      assert regular_user.type == :user
    end

    test "persists type change to database" do
      user = user_fixture()
      {:ok, admin} = Accounts.update_user_type(user, :admin)

      reloaded = Accounts.get_user!(admin.id)
      assert reloaded.type == :admin
    end

    test "only accepts :user or :admin as valid types" do
      user = user_fixture()

      assert_raise FunctionClauseError, fn ->
        Accounts.update_user_type(user, :invalid)
      end
    end
  end

  describe "admin?/1" do
    test "returns true for admin users" do
      user = user_fixture()
      {:ok, admin} = Accounts.update_user_type(user, :admin)

      assert Accounts.admin?(admin)
    end

    test "returns false for regular users" do
      user = user_fixture()

      refute Accounts.admin?(user)
    end

    test "returns false for nil" do
      refute Accounts.admin?(nil)
    end

    test "returns false for non-user structs" do
      refute Accounts.admin?(%{type: :admin})
    end
  end

  describe "User.type_changeset/2" do
    test "creates changeset to change type to admin" do
      user = %User{type: :user}
      changeset = User.type_changeset(user, :admin)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :type) == :admin
    end

    test "creates changeset to change type to user" do
      user = %User{type: :admin}
      changeset = User.type_changeset(user, :user)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :type) == :user
    end

    test "only accepts valid type values" do
      user = %User{type: :user}

      assert_raise FunctionClauseError, fn ->
        User.type_changeset(user, :invalid)
      end
    end
  end

  describe "database constraint" do
    test "prevents invalid type values at database level" do
      user = user_fixture()

      assert_raise Postgrex.Error, ~r/check_violation.*type_must_be_valid/, fn ->
        Ecto.Adapters.SQL.query!(
          Kanban.Repo,
          "UPDATE users SET type = 'invalid' WHERE id = $1",
          [user.id]
        )
      end
    end
  end
end
