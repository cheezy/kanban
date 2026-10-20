defmodule Kanban.Accounts.PasswordReset do
  @moduledoc """
  The password reset email flow: sending the reset link, looking up the user
  for a reset token, and setting the new password.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.deliver_user_reset_password_instructions/2`,
  `Accounts.get_user_by_reset_password_token/1` and
  `Accounts.reset_user_password/2` rather than reaching into this module
  directly.

  Reset tokens use the `"reset_password"` context. A successful reset deletes
  every token the user holds and returns those rows, so the caller can
  disconnect still-mounted LiveView sessions, and emits
  `[:kanban, :user, :password_reset_completed]` through
  `Kanban.Accounts.UserTelemetry`.

  A disabled account takes no part: it is sent no reset email, its reset
  tokens find no user, and a reset submitted after it was disabled changes
  nothing. Its password stays as it was until a site admin enables it again.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  @doc """
  Delivers the password reset email to the given user.

  A disabled user gets `{:error, :user_disabled}`: no token is created and no
  email is sent. The caller shows the same message either way, so the answer
  reveals nothing about the account.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, fn token -> "..." end)
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{disabled_at: %DateTime{}}, url_fun)
      when is_function(url_fun, 1),
      do: {:error, :user_disabled}

  def deliver_user_reset_password_instructions(user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Delivers the link to choose a first password to an account a site admin
  created by appointing it org-admin of `organization_name`. The token is the
  same `"reset_password"` token `deliver_user_reset_password_instructions/2`
  builds, with the same expiry; only the wording differs.
  """
  def deliver_org_admin_password_instructions(user, organization_name, reset_password_url_fun)
      when is_binary(organization_name) and is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)

    UserNotifier.deliver_org_admin_password_instructions(
      user,
      organization_name,
      reset_password_url_fun.(encoded_token),
      UserToken.reset_password_validity_in_minutes()
    )
  end

  @doc """
  Gets the user by reset password token. A disabled user's token finds
  nothing, like an expired one.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         %UserToken{user_id: user_id} <- Repo.one(query) do
      from(u in User, where: u.id == ^user_id and is_nil(u.disabled_at)) |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, {%User{}, []}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  Returns `{:error, :user_disabled}` and changes nothing when the account was
  disabled after its reset page opened. That is read from the database under
  a row lock, so a disable landing at the same moment is seen too.
  """
  def reset_user_password(user, attrs) do
    result =
      Repo.transaction(fn ->
        if disabled?(user), do: Repo.rollback(:user_disabled)

        result =
          user
          |> User.password_changeset(attrs)
          |> Repo.update()

        case result do
          {:ok, user} ->
            # Collect the token rows before deleting them so the caller can
            # disconnect any still-mounted LiveView sockets — deleting the rows
            # alone only stops future HTTP/reconnect attempts (W1676 M1). This
            # mirrors update_user_and_delete_all_tokens/1.
            tokens_query = UserToken.by_user_and_contexts_query(user, :all)
            tokens_to_expire = Repo.all(tokens_query)
            Repo.delete_all(tokens_query)
            {user, tokens_to_expire}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    UserTelemetry.password_reset_completed(result)
  end

  defp disabled?(%User{id: user_id}) do
    from(u in User,
      where: u.id == ^user_id,
      select: not is_nil(u.disabled_at),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> Kernel.==(true)
  end
end
