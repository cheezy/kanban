defmodule Kanban.Accounts.PasswordResetTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "reset_password"
    end
  end

  describe "get_user_by_reset_password_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "returns the user with valid token", %{user: %{id: id}, token: token} do
      assert %User{id: ^id} = Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: id)
    end

    test "does not return the user with invalid token", %{user: user} do
      refute Accounts.get_user_by_reset_password_token("oops")
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not return the user if token expired", %{user: user, token: token} do
      {1, nil} =
        from(t in UserToken, where: t.user_id == ^user.id)
        |> Repo.update_all(set: [inserted_at: ~N[2020-01-01 00:00:00]])

      refute Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "rejects a token just outside the dedicated 15-minute reset window (D105/D136)", %{
      user: user,
      token: token
    } do
      # 1 minute past the window: still valid under the old 1-day window, but
      # must be rejected under the 15-minute window the UI copy promises.
      just_outside =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-(UserToken.reset_password_validity_in_minutes() + 1), :minute)
        |> NaiveDateTime.truncate(:second)

      {1, nil} =
        from(t in UserToken, where: t.user_id == ^user.id)
        |> Repo.update_all(set: [inserted_at: just_outside])

      refute Accounts.get_user_by_reset_password_token(token)
    end

    test "still returns the user for a token just inside the 15-minute reset window (D105/D136)",
         %{
           user: %{id: id},
           token: token
         } do
      just_inside =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-(UserToken.reset_password_validity_in_minutes() - 1), :minute)
        |> NaiveDateTime.truncate(:second)

      {1, nil} =
        from(t in UserToken, where: t.user_id == ^id)
        |> Repo.update_all(set: [inserted_at: just_inside])

      assert %User{id: ^id} = Accounts.get_user_by_reset_password_token(token)
    end

    test "the enforced window matches the 15 minutes promised by the user-facing copy" do
      # The forgot-password page and the reset email both say "15 minutes"
      # (D136). If the enforced window changes, that copy must change with it.
      assert UserToken.reset_password_validity_in_minutes() == 15
    end
  end

  describe "reset_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.reset_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.reset_user_password(user, %{password: too_long})
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {updated_user, _}} =
        Accounts.reset_user_password(user, %{password: "new valid password"})

      assert is_nil(updated_user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, tokens}} =
        Accounts.reset_user_password(user, %{password: "new valid password"})

      assert length(tokens) == 1
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "returns the deleted token rows so sessions can be disconnected", %{user: user} do
      session_token = Accounts.generate_user_session_token(user)

      {:ok, {_, tokens}} =
        Accounts.reset_user_password(user, %{password: "new valid password"})

      assert [%UserToken{token: token}] = tokens
      assert token == session_token
    end
  end

  describe "reset_user_password/2 telemetry" do
    @user_events [
      [:kanban, :user, :password_changed],
      [:kanban, :user, :password_reset_completed],
      [:kanban, :user, :email_change_requested],
      [:kanban, :user, :email_changed],
      [:kanban, :user, :confirmed],
      [:kanban, :user, :name_changed],
      [:kanban, :user, :type_changed]
    ]

    setup do
      %{user: user_fixture()}
    end

    test "reset_user_password emits password_reset_completed", %{user: user} do
      attach_telemetry([:kanban, :user, :password_reset_completed])

      assert {:ok, {_user, _tokens}} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      assert_received {:telemetry_event, [:kanban, :user, :password_reset_completed], %{count: 1},
                       %{user_id: user_id}}

      assert user_id == user.id
    end

    test "an invalid password reset emits nothing", %{user: user} do
      attach_telemetry(@user_events)

      assert {:error, _changeset} = Accounts.reset_user_password(user, %{password: "short"})

      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end
  end
end
