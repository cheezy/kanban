defmodule KanbanWeb.Plugs.OAuthReturnTo do
  @moduledoc """
  Refuses a signed-out `GET /oauth/authorize` whose URL is too long to come
  back to after signing in (`KanbanWeb.UserAuth.ReturnTo`), with the device
  sign-in page's own `400`.

  A signed-out visitor is sent to log in, and only the stored return-to
  path brings them back to the confirmation page. A sign-in request whose
  path, query string included, passes `ReturnTo.max_bytes/0` cannot be
  stored in the session cookie, so the sign-in could never continue: it
  used to overflow the cookie and answer `500`. The page now says the
  request isn't valid and asks the person to start again from the app,
  before the log-in gate runs. A signed-in visit stores no return-to, so it
  is left to `KanbanWeb.OAuthController`, which checks every field.
  """

  @behaviour Plug

  alias KanbanWeb.OAuthController
  alias KanbanWeb.UserAuth.ReturnTo

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if signed_in?(conn) or ReturnTo.storable?(conn),
      do: conn,
      else: OAuthController.refuse(conn)
  end

  def call(conn, _opts), do: conn

  defp signed_in?(%Plug.Conn{assigns: %{current_scope: %{user: %{}}}}), do: true
  defp signed_in?(_conn), do: false
end
