defmodule KanbanWeb.UserSessionController do
  use KanbanWeb, :controller

  alias Kanban.Accounts
  alias Kanban.RateLimit
  alias KanbanWeb.UserAuth

  def register(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        deliver_confirmation_and_redirect(conn, user)

      {:error, %Ecto.Changeset{} = _changeset} ->
        # This shouldn't happen since LiveView validated, but handle it gracefully
        conn
        |> put_flash(:error, "An error occurred during registration. Please try again.")
        |> redirect(to: ~p"/users/register")
    end
  end

  defp deliver_confirmation_and_redirect(conn, user) do
    case Accounts.deliver_user_confirmation_instructions(
           user,
           &url(~p"/users/confirm/#{&1}")
         ) do
      {:ok, _} ->
        redirect(conn, to: ~p"/users/confirmation-pending?email=#{user.email}")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          gettext("We couldn't send the confirmation email. Use the resend button to try again.")
        )
        |> redirect(to: ~p"/users/confirmation-pending?email=#{user.email}")
    end
  end

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    rate_key = [ip: conn.remote_ip, identity: email]

    # Block a brute-force flood before doing the (expensive) password hash. The
    # counter is incremented only on failed attempts (see deny_login), so a
    # legitimate user typing the wrong password a few times is unaffected.
    case RateLimit.peek(:login, rate_key) do
      {:error, {:rate_limited, _}} ->
        deny_login_rate_limited(conn, email)

      :ok ->
        do_create(conn, email, password, user_params, info, rate_key)
    end
  end

  defp do_create(conn, email, password, user_params, info, rate_key) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %{confirmed_at: nil} ->
        # Only shown after the password verified, so this discloses nothing
        # to an attacker probing for registered emails.
        conn
        |> put_flash(
          :error,
          gettext(
            "You must confirm your account before signing in. Check your email for a confirmation link."
          )
        )
        |> redirect(to: ~p"/users/confirmation-pending?email=#{email}")

      nil ->
        # Invalid credentials — the brute-force signal. Count it against the
        # login budget so repeated guesses eventually trip the limiter.
        RateLimit.record_failure(:login, rate_key)

        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        deny_login(conn, email, "Invalid email or password")

      user ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)
    end
  end

  defp deny_login(conn, email, message) do
    conn
    |> put_flash(:error, message)
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  # Uniform with deny_login so an attacker cannot distinguish "throttled" from
  # "wrong password" (both are a generic failure + redirect back to log-in).
  defp deny_login_rate_limited(conn, email) do
    conn
    |> put_flash(
      :error,
      gettext("Too many attempts. Please wait a few minutes and try again.")
    )
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
