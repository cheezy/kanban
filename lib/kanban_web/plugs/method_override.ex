defmodule KanbanWeb.Plugs.MethodOverride do
  @moduledoc """
  `Plug.MethodOverride` for the endpoint, skipped on the machine API paths
  (D461).

  `Plug.MethodOverride` turns a `POST` whose body carries `_method` into the
  verb that field names. Browser forms need that: a Phoenix link with
  `method: :delete` (log out, the side-nav and danger-zone links) posts
  `_method=delete` and must reach its `DELETE` route.

  The JSON APIs must not: they answer only the verbs they declare. Run
  endpoint-wide, the override let a `POST` with a JSON body of
  `{"_method": "DELETE"}` reach `DELETE /api/me/devices/current`, which
  defeats verb-based logging, rate limits and any proxy rule keyed on the
  verb. So these paths are passed through untouched, and a `POST` there stays
  a `POST`, whatever its body says:

    * `/api` and everything under it, `/api/me` included
    * `/scim`
    * `/oauth/token` and `/oauth/revoke`, the device sign-in endpoints
      (the browser's `/oauth/authorize` keeps the override, as every other
      browser path does)
    * `/.well-known`

  The set is close to the machine paths `KanbanWeb.PathScope` names for
  `KanbanWeb.Plugs.Parsers`, with two differences. `PathScope` names only
  `/.well-known/stride-audit-signing-keys`, while this plug skips the whole of
  `/.well-known`, whose routes are all `GET`s and are read by machines, not
  browsers. And `PathScope` puts every `/oauth` path under the token API
  except the browser's `/oauth/authorize` and the paths under it (D462), so
  an unrouted path there gets that API's JSON error, while this plug skips
  only the two routed endpoints: an unrouted `/oauth` path has no verb to
  protect.

  The paths are matched on their decoded segments, as `Phoenix.Router`
  matches routes, so a percent-encoded prefix such as `/%61pi/me` (which the
  router serves as `/api/me`) is skipped too. `URI.decode/1` leaves an
  escape that is not valid percent-encoding as it is, so such a segment is
  compared undecoded, again as the router compares it. Every other path is
  passed to `Plug.MethodOverride` unchanged. The plug sits where
  `Plug.MethodOverride` sat, before `Plug.Session` and the router, so CSRF
  protection is unchanged.
  """
  @behaviour Plug

  @oauth_api_endpoints ["token", "revoke"]

  @impl Plug
  def init(opts), do: Plug.MethodOverride.init(opts)

  @impl Plug
  def call(%Plug.Conn{path_info: path_info} = conn, opts) do
    # Phoenix.Router decodes each segment with URI.decode/1 before matching,
    # so the comparison here must too.
    if path_info |> Enum.map(&URI.decode/1) |> machine_path?() do
      conn
    else
      Plug.MethodOverride.call(conn, opts)
    end
  end

  defp machine_path?(["api" | _]), do: true
  defp machine_path?(["scim" | _]), do: true
  defp machine_path?([".well-known" | _]), do: true
  defp machine_path?(["oauth", endpoint]) when endpoint in @oauth_api_endpoints, do: true
  defp machine_path?(_segments), do: false
end
