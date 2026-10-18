defmodule Kanban.Accounts.EmailConfirmation do
  @moduledoc """
  The account confirmation email flow: looking up the user for a confirmation
  token, confirming the account, and sending the confirmation link.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.get_user_by_confirmation_token/1`, `Accounts.confirm_user/1` and
  `Accounts.deliver_user_confirmation_instructions/2` rather than reaching into
  this module directly.

  Confirmation tokens use the `"confirm"` context. A successful confirmation
  deletes all of the user's confirmation tokens and emits
  `[:kanban, :user, :confirmed]` through `Kanban.Accounts.UserTelemetry`; an
  already confirmed user gets `{:error, :already_confirmed}` and an unknown or
  expired token `{:error, :invalid_token}`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  @doc """
  Gets the user with the given confirmation token.
  """
  def get_user_by_confirmation_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %UserToken{user_id: user_id} <- Repo.one(query) do
      Accounts.get_user!(user_id)
    else
      _ -> nil
    end
  end

  @doc """
  Confirms a user account.
  """
  def confirm_user(token) do
    case run_confirm_user(token) do
      {:ok, %User{}} = ok -> UserTelemetry.confirmed(ok)
      error -> handle_confirm_error(error)
    end
  end

  defp run_confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %UserToken{user_id: user_id} <- Repo.one(query),
         %User{} = user <- Repo.get(User, user_id) do
      finalize_confirm_user(user, user_id)
    end
  end

  defp finalize_confirm_user(user, user_id) do
    with {:ok, user} <- maybe_confirm_user(user),
         {_count, nil} <- delete_confirm_tokens(user_id) do
      {:ok, user}
    end
  end

  defp handle_confirm_error(nil), do: {:error, :invalid_token}
  defp handle_confirm_error({:already_confirmed, _user}), do: {:error, :already_confirmed}

  defp handle_confirm_error(%User{confirmed_at: confirmed_at}) when not is_nil(confirmed_at),
    do: {:error, :already_confirmed}

  defp handle_confirm_error(_), do: {:error, :invalid_token}

  defp delete_confirm_tokens(user_id) do
    from(t in UserToken, where: t.user_id == ^user_id and t.context == "confirm")
    |> Repo.delete_all()
  end

  defp maybe_confirm_user(%User{confirmed_at: nil} = user) do
    user
    |> User.confirm_changeset()
    |> Repo.update()
  end

  defp maybe_confirm_user(%User{} = user) do
    {:already_confirmed, user}
  end

  @doc """
  Delivers the email confirmation instructions to the given user.
  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)

      # Delivery runs off the request path (UserNotifier.dispatch_delivery), so
      # a mailer failure can no longer be returned here — it is logged inside
      # the delivery task (never the token, confirmation URL, or SMTP
      # credentials), keeping bounces observable without re-opening the
      # timing-based enumeration channel closed by D134.
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Delivers the confirmation instructions to an account a site admin created
  by appointing it org-admin of `organization_name`. The token is the same
  `"confirm"` token `deliver_user_confirmation_instructions/2` builds; only the
  wording differs.
  """
  def deliver_org_admin_confirmation_instructions(
        %User{} = user,
        organization_name,
        confirmation_url_fun
      )
      when is_binary(organization_name) and is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)

      UserNotifier.deliver_org_admin_confirmation_instructions(
        user,
        organization_name,
        confirmation_url_fun.(encoded_token)
      )
    end
  end
end
