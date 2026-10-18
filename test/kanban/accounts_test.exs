defmodule Kanban.AccountsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.EmailConfirmation
  alias Kanban.Accounts.PasswordReset
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "does not return the user if they are disabled" do
      user = user_fixture() |> set_password()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "returns the user once they are re-enabled" do
      %{id: id} = user = user_fixture() |> set_password()
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Accounts.enable_user(disabled, admin_fixture())

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "get_user/1" do
    test "returns nil if id is invalid" do
      assert is_nil(Accounts.get_user(-1))
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user(user.id)
    end
  end

  describe "register_user/1" do
    test "creates exactly one personal workspace with the user as its only owner" do
      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert [%WorkspaceMember{role: :owner, workspace_id: workspace_id}] =
               WorkspaceMember |> where([m], m.user_id == ^user.id) |> Repo.all()

      assert %Workspace{personal: true, organization_id: nil} =
               Repo.get!(Workspace, workspace_id)

      assert Workspaces.get_personal_workspace(user).id == workspace_id
    end

    test "rolls the user back when the personal workspace cannot be created" do
      # Swap the personal/organization check for one that rejects every row.
      # The DDL is undone with the rest of the sandbox transaction.
      Repo.query!(
        "ALTER TABLE workspaces DROP CONSTRAINT workspaces_personal_iff_no_organization"
      )

      Repo.query!(
        "ALTER TABLE workspaces ADD CONSTRAINT workspaces_personal_iff_no_organization CHECK (false) NOT VALID"
      )

      email = unique_user_email()
      workspaces = Repo.aggregate(Workspace, :count)
      attach_telemetry([[:kanban, :user, :registration]])

      assert {:error, %Ecto.Changeset{} = changeset} =
               [email: email] |> valid_user_attributes() |> Accounts.register_user()

      assert %{personal: [_message]} = errors_on(changeset)
      refute Accounts.get_user_by_email(email)
      assert Repo.aggregate(Workspace, :count) == workspaces
      refute_received {:telemetry_event, [:kanban, :user, :registration], _, _}
    end

    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the upper cased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "rejects names containing HTML metacharacters (W395)" do
      for bad_name <- [
            "<script>alert(1)</script>",
            "Foo<bar",
            "Foo>bar",
            "Foo&bar",
            "Foo\nBar",
            "Foo\rBar",
            "Foo\x00Bar"
          ] do
        {:error, changeset} =
          Accounts.register_user(%{email: unique_user_email(), name: bad_name})

        assert "cannot contain HTML metacharacters or control characters" in errors_on(changeset).name,
               "expected rejection for name=#{inspect(bad_name)}, got errors=#{inspect(errors_on(changeset))}"
      end
    end

    test "accepts names containing Unicode and apostrophes" do
      attrs = valid_user_attributes(name: "José D'Acosta")
      {:ok, user} = Accounts.register_user(attrs)
      assert user.name == "José D'Acosta"
    end

    test "emits :registration straight away outside a held transaction" do
      attach_telemetry([:kanban, :user, :registration])

      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert_received {:telemetry_event, [:kanban, :user, :registration], %{count: 1},
                       %{user_id: user_id}}

      assert user_id == user.id
    end

    test "holds :registration until an enclosing after_commit/1 transaction commits" do
      attach_telemetry([:kanban, :user, :registration])

      {:ok, user} =
        Kanban.Telemetry.AfterCommit.after_commit(fn ->
          Repo.transact(fn ->
            {:ok, user} = Accounts.register_user(valid_user_attributes())
            refute_received {:telemetry_event, [:kanban, :user, :registration], _, _}
            {:ok, user}
          end)
        end)

      assert_received {:telemetry_event, [:kanban, :user, :registration], _, %{user_id: id}}
      assert id == user.id
    end

    test "emits no :registration when the enclosing transaction rolls back" do
      attach_telemetry([:kanban, :user, :registration])
      email = unique_user_email()

      assert {:error, :rolled_back} =
               Kanban.Telemetry.AfterCommit.after_commit(fn ->
                 Repo.transact(fn ->
                   {:ok, _user} = Accounts.register_user(valid_user_attributes(email: email))
                   {:error, :rolled_back}
                 end)
               end)

      refute Accounts.get_user_by_email(email)
      refute_received {:telemetry_event, [:kanban, :user, :registration], _, _}
    end
  end

  describe "change_user_email/3 name validation (W395)" do
    test "rejects names containing HTML metacharacters" do
      user = user_fixture()

      changeset = Accounts.change_user_email(user, %{name: "<img src=x>", email: user.email})

      assert "cannot contain HTML metacharacters or control characters" in errors_on(changeset).name
    end

    test "registers users with password" do
      email = unique_user_email()
      attrs = valid_user_attributes(email: email)
      {:ok, user} = Accounts.register_user(attrs)
      assert user.email == email
      assert user.hashed_password
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "update_user_name/2" do
    test "updates the name when given a valid value" do
      user = user_fixture()
      assert {:ok, updated} = Accounts.update_user_name(user, %{"name" => "Grace Hopper"})
      assert updated.name == "Grace Hopper"
      assert Accounts.get_user_by_email(user.email).name == "Grace Hopper"
    end

    test "ignores email and other fields in attrs" do
      user = user_fixture()
      other = unique_user_email()

      assert {:ok, updated} =
               Accounts.update_user_name(user, %{"name" => "Ada", "email" => other})

      assert updated.name == "Ada"
      assert updated.email == user.email
    end

    test "rejects HTML metacharacters in the name" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_user_name(user, %{"name" => "<script>alert(1)"})

      assert %{name: ["cannot contain HTML metacharacters or control characters"]} =
               errors_on(changeset)
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with an undecodable token", %{user: user} do
      # A token that is not valid Base64URL drives the decode `:error` branch
      # in verify_change_email_token_query/2 rather than a failed lookup.
      assert Accounts.update_user_email(user, "not valid base64 @@@") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
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

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      authenticated_at = DateTime.utc_now(:second) |> DateTime.add(-3600)
      user = %{user | authenticated_at: authenticated_at}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end

    test "does not return user disabled after the token was issued", %{user: user, token: token} do
      {:ok, _} = Accounts.disable_user(user, admin_fixture())
      refute Accounts.get_user_by_session_token(token)
    end

    test "returns the user again once they are re-enabled", %{user: user, token: token} do
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Accounts.enable_user(disabled, admin_fixture())

      assert {session_user, _} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "user telemetry" do
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

    test "update_user_password emits password_changed", %{user: user} do
      attach_telemetry([:kanban, :user, :password_changed])

      assert {:ok, {_user, _tokens}} =
               Accounts.update_user_password(user, %{password: "new valid password"})

      assert_received {:telemetry_event, [:kanban, :user, :password_changed], %{count: 1},
                       metadata}

      assert metadata == %{user_id: user.id}
    end

    test "invalid password change emits nothing", %{user: user} do
      attach_telemetry(@user_events)

      assert {:error, _changeset} =
               Accounts.update_user_password(user, %{
                 password: "short",
                 password_confirmation: "x"
               })

      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "deliver_user_update_email_instructions emits email_change_requested", %{user: user} do
      attach_telemetry([:kanban, :user, :email_change_requested])

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: unique_user_email()},
            user.email,
            url
          )
        end)

      assert is_binary(token)

      assert_received {:telemetry_event, [:kanban, :user, :email_change_requested], %{count: 1},
                       metadata}

      assert metadata == %{user_id: user.id}
    end

    test "update_user_email emits email_changed with the user id only", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: unique_user_email()},
            user.email,
            url
          )
        end)

      attach_telemetry([:kanban, :user, :email_changed])

      assert {:ok, _user} = Accounts.update_user_email(user, token)

      assert_received {:telemetry_event, [:kanban, :user, :email_changed], %{count: 1}, metadata}

      assert metadata == %{user_id: user.id}
    end

    test "update_user_email with an invalid token emits nothing", %{user: user} do
      attach_telemetry(@user_events)

      assert {:error, :transaction_aborted} = Accounts.update_user_email(user, "oops")

      refute_received {:telemetry_event, _event, _measurements, _metadata}
    end

    test "update_user_name emits name_changed only when the name changes", %{user: user} do
      attach_telemetry([:kanban, :user, :name_changed])

      assert {:ok, renamed} = Accounts.update_user_name(user, %{"name" => "Grace Hopper"})

      assert_received {:telemetry_event, [:kanban, :user, :name_changed], %{count: 1}, metadata}

      assert metadata == %{user_id: user.id}

      assert {:ok, _same} = Accounts.update_user_name(renamed, %{"name" => "Grace Hopper"})
      assert {:error, _changeset} = Accounts.update_user_name(renamed, %{"name" => "<b>"})

      refute_received {:telemetry_event, [:kanban, :user, :name_changed], _measurements,
                       _metadata}
    end

    test "update_user_type emits from_type and to_type only when the type changes", %{
      user: user
    } do
      attach_telemetry([:kanban, :user, :type_changed])

      assert {:ok, admin} = Accounts.update_user_type(user, :admin)

      assert_received {:telemetry_event, [:kanban, :user, :type_changed], %{count: 1}, metadata}

      assert metadata == %{user_id: user.id, from_type: :user, to_type: :admin}

      assert {:ok, _admin} = Accounts.update_user_type(admin, :admin)

      refute_received {:telemetry_event, [:kanban, :user, :type_changed], _measurements,
                       _metadata}
    end

    test "user events carry no personal data", %{user: user} do
      user_entries = Enum.filter(Kanban.Telemetry.Catalog.events(), &(&1.domain == :user))

      assert length(user_entries) == 14

      for entry <- user_entries, key <- entry.metadata do
        refute key in [:email, :name, :token, :password]
        refute Kanban.Telemetry.forbidden_key?(key)
      end

      attach_telemetry(@user_events)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: unique_user_email()},
            user.email,
            url
          )
        end)

      {:ok, user} = Accounts.update_user_email(user, token)
      {:ok, user} = Accounts.update_user_name(user, %{"name" => "Ada Lovelace"})

      {:ok, {user, _tokens}} =
        Accounts.update_user_password(user, %{password: "new valid password"})

      {:ok, _user} = Accounts.update_user_type(user, :admin)

      received = collect_events()
      assert length(received) == 5

      for {_event, metadata} <- received, {_key, value} <- metadata do
        assert is_integer(value) or is_atom(value)
        refute value in [user.email, user.name]
      end
    end
  end

  describe "facade delegation" do
    @moved_functions [
      {:deliver_user_reset_password_instructions, 2, PasswordReset},
      {:get_user_by_reset_password_token, 1, PasswordReset},
      {:reset_user_password, 2, PasswordReset},
      {:get_user_by_confirmation_token, 1, EmailConfirmation},
      {:confirm_user, 1, EmailConfirmation},
      {:deliver_user_confirmation_instructions, 2, EmailConfirmation}
    ]

    @pre_split_functions [
      get_user_by_email: 1,
      get_user_by_email_and_password: 2,
      get_user!: 1,
      get_user: 1,
      register_user: 1,
      change_user_registration: 1,
      change_user_registration: 2,
      change_user_registration: 3,
      sudo_mode?: 1,
      sudo_mode?: 2,
      change_user_email: 1,
      change_user_email: 2,
      change_user_email: 3,
      update_user_name: 2,
      update_user_email: 2,
      change_user_password: 1,
      change_user_password: 2,
      change_user_password: 3,
      update_user_password: 2,
      deliver_user_reset_password_instructions: 2,
      get_user_by_reset_password_token: 1,
      reset_user_password: 2,
      update_user_type: 2,
      admin?: 1,
      list_users: 0,
      disable_user: 2,
      enable_user: 2,
      delete_user: 2,
      two_factor_enabled?: 1,
      begin_two_factor_enrollment: 1,
      cancel_two_factor_enrollment: 1,
      confirm_two_factor_enrollment: 2,
      valid_two_factor_code?: 2,
      consume_recovery_code: 2,
      regenerate_recovery_codes: 2,
      disable_two_factor: 2,
      show_two_factor_reminder?: 1,
      dismiss_two_factor_reminder: 1,
      generate_user_session_token: 1,
      get_user_by_session_token: 1,
      get_user_by_confirmation_token: 1,
      confirm_user: 1,
      deliver_user_update_email_instructions: 3,
      deliver_user_confirmation_instructions: 2,
      delete_user_session_token: 1
    ]

    test "delegates moved functions: every pre-split public function is still exported by Kanban.Accounts" do
      Code.ensure_loaded!(Accounts)

      for {name, arity} <- @pre_split_functions do
        assert function_exported?(Accounts, name, arity),
               "Kanban.Accounts.#{name}/#{arity} is no longer exported"
      end

      assert {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Accounts)

      delegates =
        for {{:function, name, arity}, _, _, _, %{delegate_to: target}} <- docs,
            into: %{},
            do: {{name, arity}, target}

      for {name, arity, module} <- @moved_functions do
        Code.ensure_loaded!(module)
        assert function_exported?(module, name, arity)
        assert delegates[{name, arity}] == {module, name, arity}
      end
    end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:telemetry_event, event, _measurements, metadata} ->
        collect_events([{event, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
