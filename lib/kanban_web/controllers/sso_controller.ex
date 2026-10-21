defmodule KanbanWeb.SSOController do
  @moduledoc """
  The single sign-on endpoints (W2245). Both are GET routes in the public
  browser scope: the login page reaches `start/2` with a LiveView redirect
  rather than a form post, because the Content-Security-Policy's
  `form-action 'self'` would stop a browser following a form submission to
  the identity provider.

    * `GET /users/sso/start?domain=...` starts an OpenID Connect sign-in for
      the Organization that verified the email domain, keeps the flow
      (`state`, `nonce`, PKCE verifier) in the session and redirects to the
      identity provider.
    * `GET /users/sso/callback` takes the flow out of the session first, so it
      can be used once, and hands it to `Kanban.SSO.complete_oidc_login/3`. A
      successful sign-in goes through `KanbanWeb.UserAuth.log_in_user/4` with
      `sso: true`, which renews the session and marks it as signed in through
      single sign-on.

  Both are rate limited per IP (`Kanban.RateLimit` surface `:sso`) before any
  work. Every refusal shows the same message, so a response reveals nothing
  about accounts or Organizations. The decisions live in `Kanban.SSO`.
  """
  use KanbanWeb, :controller

  alias Kanban.RateLimit
  alias Kanban.SSO
  alias KanbanWeb.UserAuth

  @flow_key "sso_flow"

  def start(conn, params) do
    with :ok <- rate_limit(conn),
         {:ok, flow, url} <- SSO.begin_oidc_login(params["domain"], callback_url()) do
      conn
      |> put_session(@flow_key, flow)
      |> redirect(external: url)
    else
      {:error, {:rate_limited, _retry_after}} ->
        rate_limited(conn)

      {:error, :not_available} ->
        conn
        |> put_flash(:error, gettext("Single sign-on is not available for that email address."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, params) do
    flow = get_session(conn, @flow_key)
    conn = delete_session(conn, @flow_key)

    with :ok <- rate_limit(conn),
         {:ok, user} <-
           SSO.complete_oidc_login(flow, params, redirect_uri: callback_url(), ip: conn.remote_ip) do
      conn
      |> put_flash(:info, gettext("Welcome back!"))
      |> UserAuth.log_in_user(user, %{}, sso: true)
    else
      {:error, {:rate_limited, _retry_after}} ->
        rate_limited(conn)

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "Single sign-on could not sign you in. Contact your Organization's administrator if this continues."
          )
        )
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp rate_limit(conn), do: RateLimit.check(:sso, ip: conn.remote_ip)

  defp rate_limited(conn) do
    conn
    |> put_flash(:error, gettext("Too many attempts. Please wait a few minutes and try again."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp callback_url, do: url(~p"/users/sso/callback")
end
