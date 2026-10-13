defmodule Kanban.Accounts.EmailConfirmationTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.UserToken

  describe "get_user_by_confirmation_token/1" do
    setup do
      user = unconfirmed_user_fixture()

      {encoded_token, user_token} =
        Kanban.Accounts.UserToken.build_email_token(user, "confirm")

      Repo.insert!(user_token)
      %{user: user, token: encoded_token}
    end

    test "returns user with valid token", %{user: user, token: token} do
      found_user = Accounts.get_user_by_confirmation_token(token)
      assert found_user.id == user.id
    end

    test "returns nil for invalid token" do
      assert Accounts.get_user_by_confirmation_token("invalid-token") == nil
    end

    test "returns nil for expired token", %{token: token} do
      Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.get_user_by_confirmation_token(token) == nil
    end
  end

  describe "confirm_user/1" do
    setup do
      user = unconfirmed_user_fixture()

      {encoded_token, user_token} =
        Kanban.Accounts.UserToken.build_email_token(user, "confirm")

      Repo.insert!(user_token)
      %{user: user, token: encoded_token}
    end

    test "confirms user with valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.id == user.id
      assert confirmed_user.confirmed_at != nil
    end

    test "deletes confirmation tokens after successful confirmation", %{
      user: user,
      token: token
    } do
      assert {:ok, _} = Accounts.confirm_user(token)

      refute Repo.get_by(UserToken, user_id: user.id, context: "confirm")
    end

    test "returns error for already confirmed user", %{user: user} do
      # Confirm the user first
      {first_token, first_user_token} =
        Kanban.Accounts.UserToken.build_email_token(user, "confirm")

      Repo.insert!(first_user_token)
      {:ok, _} = Accounts.confirm_user(first_token)

      # Generate a new token and try to confirm again
      {second_token, second_user_token} =
        Kanban.Accounts.UserToken.build_email_token(user, "confirm")

      Repo.insert!(second_user_token)
      assert {:error, :already_confirmed} = Accounts.confirm_user(second_token)
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} = Accounts.confirm_user("invalid-token")
    end

    test "returns error for expired token", %{token: token} do
      Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert {:error, :invalid_token} = Accounts.confirm_user(token)
    end
  end

  describe "confirm_user/1 telemetry" do
    test "confirm_user emits confirmed only for a new confirmation" do
      user = unconfirmed_user_fixture()
      {token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      {second_token, second_user_token} = UserToken.build_email_token(user, "confirm")

      attach_telemetry([:kanban, :user, :confirmed])

      assert {:ok, _user} = Accounts.confirm_user(token)
      assert_received {:telemetry_event, [:kanban, :user, :confirmed], %{count: 1}, metadata}
      assert metadata == %{user_id: user.id}

      Repo.insert!(second_user_token)
      assert {:error, :already_confirmed} = Accounts.confirm_user(second_token)
      assert {:error, :invalid_token} = Accounts.confirm_user("invalid-token")
      refute_received {:telemetry_event, [:kanban, :user, :confirmed], _measurements, _metadata}
    end
  end
end
