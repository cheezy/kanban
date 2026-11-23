defmodule Kanban.Accounts.PasswordResetTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation

  defp disable!(user) do
    user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends nothing and creates no token for a disabled account", %{user: user} do
      disabled = disable!(user)
      # The fixture's own confirmation email.
      receive do
        {:email, _email} -> :ok
      after
        0 -> :ok
      end

      assert {:error, :user_disabled} =
               Accounts.deliver_user_reset_password_instructions(disabled, &"[TOKEN]#{&1}[TOKEN]")

      assert Repo.get_by(UserToken, user_id: user.id, context: "reset_password") == nil
      Swoosh.TestAssertions.assert_no_email_sent()
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

    test "does not return a user disabled after the link was sent", %{user: user, token: token} do
      disable!(user)

      refute Accounts.get_user_by_reset_password_token(token)
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

    test "changes nothing for an account disabled after its reset page opened", %{user: user} do
      disable!(user)
      attach_telemetry([:kanban, :user, :password_reset_completed])

      # `user` is the struct the page loaded before the disable.
      assert {:error, :user_disabled} =
               Accounts.reset_user_password(user, %{
                 password: "new valid password",
                 password_confirmation: "new valid password"
               })

      assert Repo.get!(User, user.id).hashed_password == user.hashed_password
      refute_received {:telemetry_event, [:kanban, :user, :password_reset_completed], _, _}
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

  describe "reset_user_password/2 and the user's devices (D459)" do
    setup do
      attach_telemetry([:kanban, :device, :revoked])
      user = user_fixture()
      %{user: user, scope: user_scope_fixture(user)}
    end

    test "reset_user_password/2 revokes every live device of the user and expires its tokens",
         %{user: user, scope: scope} do
      {first, first_issued} = device_with_tokens_fixture(scope)
      {second, second_issued} = device_with_tokens_fixture(scope, %{name: "Second"})
      other = device_fixture(user_scope_fixture())
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(first.id))
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(second.id))

      assert {:ok, {%User{}, _tokens}} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      for {device, issued} <- [{first, first_issued}, {second, second_issued}] do
        revoked = Repo.get!(Device, device.id)
        assert revoked.revoked_at
        assert revoked.revoked_by_id == user.id
        assert {:error, :invalid_token} = Devices.fetch_by_access_token(issued.access_token)
        assert {:error, :invalid_token} = Devices.rotate_refresh_token(issued.refresh_token)

        topic = Revocation.topic(device.id)
        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      end

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], _,
                      %{reason: :password_changed}}

      assert is_nil(Repo.get!(Device, other.id).revoked_at)
    end

    test "leaves an already revoked device as it is and still resets", %{
      user: user,
      scope: scope
    } do
      gone = device_fixture(scope)
      {:ok, revoked} = Devices.revoke_device(scope, gone)
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(gone.id))

      assert {:ok, {_user, _tokens}} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      assert Repo.get!(Device, gone.id).revoked_at == revoked.revoked_at
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "a user with no devices resets normally", %{user: user} do
      assert {:ok, {_user, _tokens}} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      assert %User{} = Accounts.get_user_by_email_and_password(user.email, "new valid password")
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
    end

    test "an authorization code issued before the reset cannot sign a device in after it",
         %{user: user, scope: scope} do
      code = authorization_code_fixture(scope)
      other_code = authorization_code_fixture(user_scope_fixture())

      assert {:ok, {_user, _tokens}} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      assert {:error, :invalid_grant} = redeem_authorization_code(code)
      refute Repo.get_by(Device, user_id: user.id)
      assert {:ok, _issued} = redeem_authorization_code(other_code)
    end

    test "a failed password reset leaves an authorization code redeemable",
         %{user: user, scope: scope} do
      code = authorization_code_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.reset_user_password(user, %{password: "short"})

      assert {:ok, _issued} = redeem_authorization_code(code)
    end

    test "A failed password reset (invalid params) leaves devices untouched", %{
      user: user,
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope)
      Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))

      assert {:error, %Ecto.Changeset{}} =
               Accounts.reset_user_password(user, %{
                 password: "not valid",
                 password_confirmation: "another"
               })

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
      assert {:ok, %Device{}} = Devices.fetch_by_access_token(issued.access_token)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
    end

    test "a reset refused for a disabled account leaves devices untouched", %{
      user: user,
      scope: scope
    } do
      device = device_fixture(scope)
      disable!(user)

      assert {:error, :user_disabled} =
               Accounts.reset_user_password(user, %{password: "new valid password"})

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
      refute_receive {:telemetry_event, [:kanban, :device, :revoked], _, _}
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
