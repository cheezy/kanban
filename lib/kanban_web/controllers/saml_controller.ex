defmodule KanbanWeb.SAMLController do
  @moduledoc """
  The SAML 2.0 service provider endpoints (W2246). A SAML sign-in starts at
  `GET /users/sso/start` (`KanbanWeb.SSOController`), which falls back to the
  Organization's SAML connection when it has no OpenID Connect one.

    * `POST /users/sso/saml/:organization_id/acs` — the assertion consumer
      service. The identity provider's browser POST is cross-site, so the
      route has its own `:saml` pipeline without CSRF protection, and the
      SameSite=Lax session cookie is not sent with it: the request is found
      by its RelayState in the database instead (`Kanban.SSO.SAMLLogin`), and
      must match the signed SameSite=None cookie `put_relay_cookie/2` set
      when the sign-in started, so a response cannot be posted into another
      browser (login CSRF); the cookie is deleted on every ACS request. The
      response is checked against that Organization's connection only. A
      successful sign-in goes through `KanbanWeb.UserAuth.log_in_user/4` with
      `sso: true`, which renews the session, marks it as signed in through
      single sign-on and returns the person to the request's stored local
      path. Rate limited per IP (`Kanban.RateLimit` surface `:sso`) before
      any work; every refusal shows the same message.
    * `GET /org/sso/saml/metadata` — Stride's SP metadata for the signed-in
      org-admin's Organization, as a download. The route's pipeline runs
      `require_org_admin_user` (re-declared here) and the action checks the
      paid gate; the Organization comes from the org-admin's own membership,
      never from params.
  """
  use KanbanWeb, :controller

  import KanbanWeb.UserAuth, only: [require_org_admin_user: 2]

  alias Kanban.RateLimit
  alias Kanban.SSO
  alias Kanban.SSO.SAML
  alias Kanban.SSO.SAML.Metadata
  alias KanbanWeb.UserAuth

  plug :require_org_admin_user when action in [:metadata]

  @relay_cookie "_kanban_saml_relay"
  @relay_cookie_opts [
    sign: true,
    max_age: 600,
    http_only: true,
    secure: true,
    same_site: "None",
    path: "/users/sso/saml"
  ]

  @doc """
  Binds a SAML sign-in's RelayState token to this browser with a signed
  cookie. It must be SameSite=None (and so Secure) to come back with the
  identity provider's cross-site POST, and it is scoped to the SAML path.
  """
  @spec put_relay_cookie(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_relay_cookie(conn, relay_token),
    do: put_resp_cookie(conn, @relay_cookie, relay_token, @relay_cookie_opts)

  # Reads the binding and deletes the cookie, so it is used once.
  defp take_relay_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@relay_cookie])
    binding = conn.cookies[@relay_cookie]

    {delete_resp_cookie(conn, @relay_cookie, Keyword.delete(@relay_cookie_opts, :max_age)),
     binding}
  end

  def acs(conn, params) do
    {conn, binding} = take_relay_cookie(conn)
    sign_in(conn, params, binding)
  end

  defp sign_in(conn, %{"organization_id" => organization_id} = params, binding) do
    with :ok <- RateLimit.check(:sso, ip: conn.remote_ip),
         {:ok, user, return_to} <- complete(conn, organization_id, params, binding) do
      conn
      |> put_return_to(return_to)
      |> put_flash(:info, gettext("Welcome back!"))
      |> UserAuth.log_in_user(user, %{}, sso: true)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp complete(conn, organization_id, params, binding),
    do: SSO.complete_saml_login(organization_id, params, binding: binding, ip: conn.remote_ip)

  defp refuse(conn, {:rate_limited, _retry_after}) do
    conn
    |> put_flash(:error, gettext("Too many attempts. Please wait a few minutes and try again."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp refuse(conn, _reason) do
    conn
    |> put_flash(
      :error,
      gettext(
        "Single sign-on could not sign you in. Contact your Organization's administrator if this continues."
      )
    )
    |> redirect(to: ~p"/users/log-in")
  end

  # The body is Stride's own SP metadata (`Metadata.sp_metadata/1` escapes
  # every value), sent as an XML attachment, not HTML.
  # sobelow_skip ["XSS.SendResp"]
  def metadata(conn, _params) do
    organization = conn.assigns.current_organization

    case SSO.check_access(conn.assigns.current_scope, :controller) do
      :ok ->
        conn
        |> put_resp_content_type("application/samlmetadata+xml")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="stride-saml-metadata.xml")
        )
        |> send_resp(200, organization.id |> SAML.service_provider() |> Metadata.sp_metadata())

      {:error, {:plan_required, :sso}} ->
        conn
        |> put_flash(:error, gettext("Single sign-on needs a paid plan."))
        |> redirect(to: ~p"/org/sso")
    end
  end

  defp put_return_to(conn, path) when is_binary(path),
    do: put_session(conn, :user_return_to, path)

  defp put_return_to(conn, nil), do: conn
end
