defmodule Kanban.Accounts.SSOUsersTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Workspaces

  describe "register_sso_user/1" do
    test "creates a confirmed passwordless user with a personal workspace and telemetry" do
      attach_telemetry([:kanban, :user, :registration])
      email = unique_user_email()

      assert {:ok, %User{} = user} = Accounts.register_sso_user(%{email: email, name: "Pat"})
      assert user.confirmed_at
      assert is_nil(user.hashed_password)
      assert user.name == "Pat"
      assert Workspaces.get_personal_workspace(user)

      user_id = user.id

      assert_receive {:telemetry_event, [:kanban, :user, :registration], %{count: 1},
                      %{user_id: ^user_id}}
    end

    test "drops an invalid name instead of failing" do
      assert {:ok, user} = Accounts.register_sso_user(%{email: unique_user_email(), name: "<b>"})
      assert is_nil(user.name)
    end

    test "refuses a taken or invalid email" do
      existing = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.register_sso_user(%{email: existing.email, name: nil})

      assert "has already been taken" in errors_on(changeset).email

      assert {:error, %Ecto.Changeset{}} =
               Accounts.register_sso_user(%{email: "no-at", name: nil})
    end
  end

  describe "secure_linked_unconfirmed_user/1" do
    test "confirms, removes the password and deletes every token" do
      user = unconfirmed_user_fixture() |> set_password()
      _session = Accounts.generate_user_session_token(user)

      assert {:ok, secured} = Accounts.secure_linked_unconfirmed_user(user)
      assert secured.confirmed_at
      assert is_nil(secured.hashed_password)
      assert from(t in UserToken, where: t.user_id == ^user.id) |> Repo.all() == []
    end

    test "leaves a confirmed account as it is" do
      user = user_fixture() |> set_password()
      token = Accounts.generate_user_session_token(user)

      assert {:ok, ^user} = Accounts.secure_linked_unconfirmed_user(user)
      assert {%User{}, _at} = Accounts.get_user_by_session_token(token)
    end
  end
end
