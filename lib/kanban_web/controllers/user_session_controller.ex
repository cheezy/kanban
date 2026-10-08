defmodule KanbanWeb.UserSessionController do
  use KanbanWeb, :controller

  alias Kanban.Accounts
  alias Kanban.Accounts.TwoFactor
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.RateLimit
  alias KanbanWeb.TwoFactorPending
  alias KanbanWeb.UserAuth

  # The settings LiveView is sudo-gated at mount, but the password-change POST
  # is a separate controller route — re-check sudo here so a direct POST that
  # bypasses the LiveView also requires recent re-authentication (D155).
  plug :require_sudo_mode when action in [:update_password]

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
    # Delivery is dispatched off the request path (UserNotifier), so a mailer
    # failure cannot be surfaced in-band anymore — it is logged in the delivery
    # task instead. The user always lands on confirmation-pending, which offers
    # a resend button if the email never arrives.
    _ = Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))

    redirect(conn, to: ~p"/users/confirmation-pending?email=#{user.email}")
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
        Kanban.AuditLog.event(:login_failed, email: email, ip: conn.remote_ip)

        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        deny_login(conn, email, "Invalid email or password")

      user ->
        start_session(conn, user, user_params, info)
    end
  end

  # The password is right. With two-factor on, the session gets only a
  # pending-login marker and the user is sent to the challenge; the session
  # token is issued by verify_two_factor/2 once a code is accepted. This runs
  # after the confirmation check, so nothing about two-factor is revealed
  # before the password has been verified.
  defp start_session(conn, user, user_params, info) do
    if Accounts.two_factor_enabled?(user) do
      conn
      |> TwoFactorPending.put(user, user_params["remember_me"] == "true")
      |> redirect(to: ~p"/users/two-factor")
    else
      conn
      |> put_flash(:info, info)
      |> maybe_put_two_factor_reminder(user)
      |> UserAuth.log_in_user(user, user_params)
    end
  end

  # Decided once, after the password verified, and only on this path: the
  # two-factor challenge and a password change also call log_in_user/3 and
  # must not set it. The landing LiveView reads the flash in
  # KanbanWeb.TwoFactorReminderOnMount; no page queries two-factor itself.
  defp maybe_put_two_factor_reminder(conn, user) do
    if Accounts.show_two_factor_reminder?(user) do
      put_flash(conn, :two_factor_reminder, true)
    else
      conn
    end
  end

  @doc """
  The second step of signing in for a user with two-factor turned on: checks a
  TOTP code or an unused recovery code against the pending-login marker set
  by the password step, and only then logs the user in.

  Attempts are counted per user on `:two_factor` (inside
  `Kanban.Accounts.TwoFactor`), and wrong codes per IP on
  `:two_factor_challenge` and per user over a day on `:two_factor_daily`; any
  of them refuses the attempt with the same message as a throttled password
  login.
  """
  def verify_two_factor(conn, params) do
    case open_challenge(conn) do
      {:ok, user, pending} -> check_challenge_code(conn, user, pending, params)
      {:error, :rate_limited} -> deny_challenge(conn, rate_limited_message())
      {:error, _expired_or_ineligible} -> deny_challenge(conn, challenge_expired_message())
    end
  end

  # The marker, then the IP limit (before any database work), then the
  # account, then its day-long failure cap. The per-user :two_factor limit is
  # applied atomically by Kanban.Accounts.TwoFactor when the code is checked.
  defp open_challenge(conn) do
    with {:ok, pending} <- TwoFactorPending.get(conn),
         :ok <- peek_challenge_ip(conn),
         {:ok, user} <- fetch_challenge_user(pending),
         :ok <- peek_daily_cap(user) do
      {:ok, user, pending}
    end
  end

  # Blocks an IP flood before any database work, like the :login peek.
  defp peek_challenge_ip(conn) do
    case RateLimit.peek(:two_factor_challenge, ip: conn.remote_ip) do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
    end
  end

  # The account may have changed since the password step: it must still
  # exist, be enabled and confirmed, and still have two-factor on.
  defp fetch_challenge_user(%{user_id: user_id}) do
    case Accounts.get_user(user_id) do
      %User{disabled_at: nil, confirmed_at: %DateTime{}} = user ->
        if Accounts.two_factor_enabled?(user), do: {:ok, user}, else: {:error, :ineligible}

      _missing_disabled_or_unconfirmed ->
        {:error, :ineligible}
    end
  end

  defp peek_daily_cap(%User{id: user_id}) do
    case RateLimit.peek(:two_factor_daily, identity: "user:#{user_id}") do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
    end
  end

  defp check_challenge_code(conn, user, pending, params) do
    {method, code} = challenge_input(params)

    case verify_challenge_code(user, method, code) do
      :ok -> complete_two_factor_login(conn, user, pending, method)
      {:error, :rate_limited} -> deny_challenge(conn, rate_limited_message())
      {:error, :invalid_code} -> challenge_failed(conn, user, method)
    end
  end

  defp challenge_input(%{"two_factor" => %{"code" => code} = input}) when is_binary(code) do
    {challenge_method(input["mode"]), code}
  end

  defp challenge_input(_params), do: {:totp, ""}

  defp challenge_method("recovery"), do: :recovery_code
  defp challenge_method(_mode), do: :totp

  # An attempt refused by the per-user limit is told it was throttled, not
  # that its code was wrong. Two-factor turned off since the account check
  # reads as a wrong code.
  defp verify_challenge_code(user, :totp, code) do
    case TwoFactor.verify_code(user, code) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
      {:error, _invalid_or_not_enabled} -> {:error, :invalid_code}
    end
  end

  defp verify_challenge_code(user, :recovery_code, code) do
    Accounts.consume_recovery_code(user, code)
  end

  # The marker is deleted explicitly: on a sudo re-authentication the user is
  # already logged in, so UserAuth does not clear the session.
  defp complete_two_factor_login(conn, user, pending, method) do
    if method == :recovery_code do
      AuditLog.event(:two_factor_recovery_code_used, user_id: user.id, ip: conn.remote_ip)
    end

    AuditLog.event(:login_succeeded_two_factor,
      user_id: user.id,
      ip: conn.remote_ip,
      method: method
    )

    conn
    |> TwoFactorPending.delete()
    |> put_flash(:info, two_factor_success_message(method))
    |> UserAuth.log_in_user(user, remember_me_params(pending))
  end

  defp remember_me_params(%{remember_me: true}), do: %{"remember_me" => "true"}
  defp remember_me_params(_pending), do: %{}

  defp two_factor_success_message(:totp), do: gettext("Welcome back!")

  defp two_factor_success_message(:recovery_code) do
    gettext(
      "Welcome back! You signed in with a recovery code, which can't be used again. Create new recovery codes in Settings → Two-factor."
    )
  end

  # A wrong code keeps the marker, so the user can try again until a limit or
  # the marker's five minutes run out.
  defp challenge_failed(conn, user, method) do
    RateLimit.record_failure(:two_factor_challenge, ip: conn.remote_ip)
    RateLimit.record_failure(:two_factor_daily, identity: "user:#{user.id}")

    AuditLog.event(:two_factor_challenge_failed,
      user_id: user.id,
      ip: conn.remote_ip,
      method: method
    )

    conn
    |> put_flash(:error, gettext("That code is not valid. Check it and try again."))
    |> redirect(to: challenge_path(method))
  end

  defp challenge_path(:recovery_code), do: ~p"/users/two-factor?mode=recovery"
  defp challenge_path(:totp), do: ~p"/users/two-factor"

  defp deny_challenge(conn, message) do
    conn
    |> TwoFactorPending.delete()
    |> put_flash(:error, message)
    |> redirect(to: ~p"/users/log-in")
  end

  defp challenge_expired_message do
    gettext("Your sign-in attempt expired. Please sign in again.")
  end

  defp rate_limited_message do
    gettext("Too many attempts. Please wait a few minutes and try again.")
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
    |> put_flash(:error, rate_limited_message())
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    {:ok, {user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    # Logs the current user straight back in rather than repeating the
    # password login: the :require_sudo_mode plug already required a recent
    # sign-in, which for a two-factor user included the second factor, so
    # changing the password does not send them to the challenge again.
    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> put_flash(:info, "Password updated successfully!")
    |> UserAuth.log_in_user(user, user_params)
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  # Mirrors the `:require_sudo_mode` LiveView on_mount (user_auth.ex): a
  # credential change requires a session authenticated within the last 10
  # minutes. Not in sudo → bounce to the re-auth (log-in) page. The window
  # matches the on_mount so the two gates behave identically.
  defp require_sudo_mode(conn, _opts) do
    user = conn.assigns.current_scope && conn.assigns.current_scope.user

    if user && Accounts.sudo_mode?(user, -10) do
      conn
    else
      Kanban.AuditLog.event(:permission_denied,
        user_id: user && user.id,
        ip: conn.remote_ip,
        gate: :require_sudo_mode
      )

      conn
      |> put_flash(:error, "You must re-authenticate to access this page.")
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end
end
