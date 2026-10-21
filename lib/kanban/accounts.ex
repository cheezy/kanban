defmodule Kanban.Accounts do
  @moduledoc """
  The Accounts context.

  Admin user management (`Kanban.Accounts.AdminManagement`), TOTP two-factor
  authentication (`Kanban.Accounts.TwoFactor`), the password reset email flow
  (`Kanban.Accounts.PasswordReset`) and the account confirmation email flow
  (`Kanban.Accounts.EmailConfirmation`) are delegated below.
  """

  import Ecto.Query, warn: false
  alias Kanban.Repo

  alias Kanban.Accounts.AccountDeletion
  alias Kanban.Accounts.AdminManagement
  alias Kanban.Accounts.EmailConfirmation
  alias Kanban.Accounts.PasswordReset
  alias Kanban.Accounts.TwoFactor
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Workspaces

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  Returns `nil` for a disabled user, so callers refuse the login through the
  same path as a wrong password and reveal nothing about the account.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

      iex> get_user_by_email_and_password("disabled@example.com", "correct_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    # The password is always verified first: returning early for a disabled user
    # would skip the hash comparison and leak the account's state through
    # response timing.
    if User.valid_password?(user, password) and is_nil(user.disabled_at), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, returning `nil` if the User does not exist.

  ## Examples

      iex> get_user(123)
      %User{}

      iex> get_user(456)
      nil

  """
  def get_user(id), do: Repo.get(User, id)

  ## User registration

  @doc """
  Registers a user with password.

  Emits `[:kanban, :user, :registration]` through
  `Kanban.Telemetry.AfterCommit.defer/2`: straight away on its own, or once the
  enclosing transaction commits when the caller wraps it in
  `Kanban.Telemetry.AfterCommit.after_commit/1`, as
  `Kanban.Organizations.appoint_org_admin_by_email/4` does.

  The user's hidden personal workspace (`Kanban.Workspaces`) is created in the
  same transaction, so a user never exists without one: if the workspace insert
  fails, the user is rolled back too and that step's changeset is returned.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:personal_workspace, fn _repo, %{user: user} ->
      Workspaces.create_personal_workspace(user)
    end)
    |> Repo.transaction()
    |> handle_registration_result()
  end

  defp handle_registration_result({:ok, %{user: user}}) do
    AfterCommit.defer(fn ->
      Kanban.Telemetry.emit([:kanban, :user, :registration], %{count: 1}, %{user_id: user.id})
    end)

    {:ok, user}
  end

  defp handle_registration_result({:error, _step, changeset, _changes}), do: {:error, changeset}

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Kanban.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates only the user's display name. Returns `{:ok, user}` on success
  or `{:error, changeset}` if the name fails validation.

  Used by the Profile form on `/users/settings` when the user submits
  without changing their email — `change_user_email/3` requires the email
  to actually change.
  """
  def update_user_name(user, attrs) do
    changeset = User.name_changeset(user, attrs)

    changeset
    |> Repo.update()
    |> UserTelemetry.name_changed(changeset)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    result =
      Repo.transact(fn ->
        with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
             %UserToken{sent_to: email} <- Repo.one(query),
             {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
             {_count, _result} <-
               Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
          {:ok, user}
        else
          _ -> {:error, :transaction_aborted}
        end
      end)

    UserTelemetry.email_changed(result)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Kanban.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
    |> UserTelemetry.password_changed()
  end

  @doc """
  Updates a user's type.

  This should only be called programmatically by admins.

  ## Examples

      iex> update_user_type(user, :admin)
      {:ok, %User{}}

  """
  def update_user_type(user, type) when type in [:user, :admin] do
    user
    |> User.type_changeset(type)
    |> Repo.update()
    |> UserTelemetry.type_changed(user.type)
  end

  @doc """
  Checks if a user is an admin.

  ## Examples

      iex> admin?(user)
      true

  """
  def admin?(%User{type: :admin}), do: true
  def admin?(_), do: false

  ## Admin user management

  defdelegate list_users(), to: AdminManagement
  defdelegate disable_user(user, current_user), to: AdminManagement
  defdelegate enable_user(user, current_user), to: AdminManagement
  defdelegate delete_user(user, current_user), to: AdminManagement

  ## Self-service account deletion (see `Kanban.Accounts.AccountDeletion`)

  defdelegate deletion_blockers(user), to: AccountDeletion
  defdelegate deletion_warnings(user), to: AccountDeletion
  defdelegate delete_own_account(scope, password, confirmation), to: AccountDeletion
  defdelegate account_deletion_phrase(), to: AccountDeletion, as: :confirmation_phrase

  ## Two-factor authentication

  defdelegate two_factor_enabled?(user), to: TwoFactor, as: :enabled?
  defdelegate begin_two_factor_enrollment(user), to: TwoFactor, as: :begin_enrollment
  defdelegate cancel_two_factor_enrollment(user), to: TwoFactor, as: :cancel_enrollment
  defdelegate confirm_two_factor_enrollment(user, code), to: TwoFactor, as: :confirm_enrollment
  defdelegate valid_two_factor_code?(user, code), to: TwoFactor, as: :valid_code?
  defdelegate consume_recovery_code(user, code), to: TwoFactor
  defdelegate regenerate_recovery_codes(user, code), to: TwoFactor
  defdelegate disable_two_factor(user, code), to: TwoFactor, as: :disable
  defdelegate show_two_factor_reminder?(user), to: TwoFactor, as: :show_reminder?
  defdelegate dismiss_two_factor_reminder(user), to: TwoFactor, as: :dismiss_reminder

  ## Password reset

  defdelegate deliver_user_reset_password_instructions(user, reset_password_url_fun),
    to: PasswordReset

  defdelegate deliver_org_admin_password_instructions(
                user,
                organization_name,
                reset_password_url_fun
              ),
              to: PasswordReset

  defdelegate get_user_by_reset_password_token(token), to: PasswordReset
  defdelegate reset_user_password(user, attrs), to: PasswordReset

  ## Email confirmation

  defdelegate get_user_by_confirmation_token(token), to: EmailConfirmation
  defdelegate confirm_user(token), to: EmailConfirmation

  defdelegate deliver_user_confirmation_instructions(user, confirmation_url_fun),
    to: EmailConfirmation

  defdelegate deliver_org_admin_confirmation_instructions(
                user,
                organization_name,
                confirmation_url_fun
              ),
              to: EmailConfirmation

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns every session token row `user` has, for disconnecting their open
  LiveView pages when an administrator disables them. The rows are kept, so
  re-enabling the account restores those sessions.
  """
  @spec list_session_tokens(User.t()) :: [UserToken.t()]
  def list_session_tokens(%User{} = user) do
    user
    |> UserToken.by_user_and_contexts_query(["session"])
    |> Repo.all()
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserTelemetry.email_change_requested(user)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    UserToken
    |> where([t], t.token == ^token and t.context == "session")
    |> Repo.delete_all()

    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
