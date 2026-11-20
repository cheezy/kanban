defmodule KanbanWeb.OAuthController do
  @moduledoc """
  The browser half of device sign-in
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §9.1).

    * `authorize` (`GET /oauth/authorize`) checks the sign-in request and shows
      a confirmation page naming the device, with **Allow** and **Cancel**.
    * `confirm` (`POST /oauth/authorize`, CSRF-protected) checks the request
      again — its hidden fields came back from the browser — then **Allow**
      issues a one-time, hashed, 60-second authorization code and redirects to
      the app with `code` and `state`, and **Cancel** redirects with
      `error=access_denied` and `state`.

  Both routes run in the `:browser` pipeline behind `:require_authenticated_user`
  and the Organization two-factor gate, so the person signs in exactly as on the
  web. Ahead of the log-in gate, `KanbanWeb.Plugs.OAuthReturnTo` refuses a
  signed-out request too long to come back to after signing in, with this
  page's 400 (`refuse/1`). The page is shown even to a browser that is already signed in: without
  it, a link someone else sent could deliver a code to an app that isn't the
  person's. A request that fails any check is refused with a 400 page and is
  never redirected to the app, and the app is reached only through
  `Kanban.Devices.Clients.callback_uri/1`, so a redirect target never comes
  from a parameter. The code itself is never logged or stored in plain text.

  Allow hands the session's single sign-on mark
  (`KanbanWeb.UserAuth.OrganizationTwoFactorGate.sso_session_key/0`) to the
  code, which records it only when it names the person's own Organization,
  the session the two-factor gate exempts. The device the code signs in
  then carries that exemption to its refreshes
  (`Kanban.Devices.SsoExemption`). Only the server-written session value is
  read, never a request parameter.
  """

  use KanbanWeb, :controller

  alias Kanban.Devices
  alias Kanban.Devices.Clients
  alias KanbanWeb.Plugs.CspNonce
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  plug :harden_response

  def authorize(conn, params) do
    with false <- Clients.repeated_parameter?(conn.query_string),
         {:ok, request} <- Clients.validate_authorize_request(params) do
      render_confirmation(conn, request)
    else
      _error -> render_invalid(conn)
    end
  end

  def confirm(conn, %{"decision" => "allow"} = params) do
    with {:ok, request} <- confirmed_request(conn, params),
         {:ok, %{code: code}} <-
           Devices.create_authorization_code(
             conn.assigns.current_scope,
             Clients.code_attrs(request),
             DateTime.utc_now(),
             sso_mark: get_session(conn, OrganizationTwoFactorGate.sso_session_key())
           ) do
      redirect(conn, external: Clients.callback_uri(code: code, state: request.state))
    else
      _error -> render_invalid(conn)
    end
  end

  def confirm(conn, %{"decision" => "cancel"} = params) do
    case confirmed_request(conn, params) do
      {:ok, request} ->
        redirect(conn,
          external: Clients.callback_uri(error: "access_denied", state: request.state)
        )

      {:error, _reason} ->
        render_invalid(conn)
    end
  end

  def confirm(conn, _params), do: render_invalid(conn)

  @doc """
  Answers a sign-in request with this page's `400` and halts, for a plug
  that refuses one before the controller runs
  (`KanbanWeb.Plugs.OAuthReturnTo`). The response carries the same
  hardening headers as every other answer of this page.
  """
  @spec refuse(Plug.Conn.t()) :: Plug.Conn.t()
  def refuse(conn) do
    conn
    |> put_view(html: KanbanWeb.OAuthHTML)
    |> harden_response([])
    |> render_invalid()
    |> halt()
  end

  # The confirmation form posts its fields in the body and nothing in the URL,
  # so a confirm POST carrying a query string did not come from the page:
  # Plug would otherwise merge query fields (decision included) into params.
  defp confirmed_request(%Plug.Conn{query_string: ""}, params),
    do: Clients.validate_authorize_request(params)

  defp confirmed_request(_conn, _params), do: {:error, :query_string}

  defp render_confirmation(conn, request) do
    render(conn, :authorize, request: request, page_title: gettext("Sign in to Stride"))
  end

  defp render_invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> render(:authorize, request: nil, page_title: gettext("Sign in to Stride"))
  end

  # The form's Allow and Cancel POSTs redirect to the app's private-use scheme,
  # and browsers apply form-action to those redirects. The page's own URL
  # carries the PKCE challenge and state, so it is never cached or sent on in
  # a Referer.
  defp harden_response(conn, _opts) do
    conn
    |> CspNonce.put_policy(form_action: [Clients.redirect_scheme_source()])
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
  end
end
