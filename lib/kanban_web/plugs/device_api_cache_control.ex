defmodule KanbanWeb.Plugs.DeviceApiCacheControl do
  @moduledoc """
  The `cache-control` of every person-API response (`/api/me/*`,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §9.1, decided 2026-11-19).

  No route sets an `etag` yet, so today every `/api/me` response is
  `private, no-store`. The rule below still follows the header, so a read
  that adds an etag later is revalidated without a change here.

  It is the first plug of the router's `:device_api` pipeline and sets the
  header in a `before_send` callback, so it covers every response the
  pipeline sends: a success, a controller's error, and the refusals of the
  plugs after it (`KanbanWeb.Plugs.AppVersion`,
  `KanbanWeb.Plugs.AuthenticateDeviceToken`), whose `401` and `429` halt
  the conn before any controller runs.

    * A response that carries an `etag` is `private, max-age=0,
      must-revalidate`: the app may keep it and revalidate it with
      `If-None-Match`, which is what the etag is for. The rule follows the
      header, not the route, so any read that sets an etag gets it, and a
      route that sets none never does. None sets one today; the review
      reads are the likely first.
    * Every other response is `private, no-store`: a phone, a proxy or an
      HTTP cache never keeps a person's data, a token refusal or an error.

  Callbacks run in the reverse of the order they were registered, so this
  one, registered first, runs after every callback a later plug or action
  registers and sees the response's final headers. When
  `KanbanWeb.Plugs.AuthenticateDeviceToken` turns a read into a `401` just
  before it is sent, it drops the read's etag, and the refusal goes out as
  `no-store`.
  """

  @behaviour Plug

  import Plug.Conn

  @no_store "private, no-store"
  @revalidate "private, max-age=0, must-revalidate"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &put_cache_control/1)

  @doc """
  Sets `cache-control` on `conn` from its response headers: `#{@revalidate}`
  when it carries an `etag`, `#{@no_store}` otherwise.
  """
  @spec put_cache_control(Plug.Conn.t()) :: Plug.Conn.t()
  def put_cache_control(conn) do
    case get_resp_header(conn, "etag") do
      [] -> put_resp_header(conn, "cache-control", @no_store)
      [_etag | _rest] -> put_resp_header(conn, "cache-control", @revalidate)
    end
  end
end
