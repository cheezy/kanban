defmodule KanbanWeb.Plugs.PutNoindex do
  @moduledoc """
  Marks a response `noindex` for search engines (W2890).

  It assigns `noindex: true`, which every root layout passes to
  `KanbanWeb.SeoComponents.seo_head/1` so an HTML page renders
  `<meta name="robots" content="noindex, nofollow">`, and it sets the
  `x-robots-tag: noindex, nofollow` response header, so the instruction also
  holds for a crawler that never parses the HTML and for a response with no
  page at all (a redirect, or the empty body of a one-click unsubscribe).

  The header is set directly in `call/2` rather than in a `before_send`
  callback: response headers persist on the conn, so a later plug that
  halts, a redirect or a `send_resp` all keep it.

  The router pipes it through the `:put_noindex` pipeline for the signed-in
  scopes, the token and account pages and `/oauth/authorize`, and
  `KanbanWeb.NotificationUnsubscribeController` plugs it directly. Noindex is
  a request to crawlers, not access control.
  """

  @behaviour Plug

  import Plug.Conn

  @value "noindex, nofollow"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> assign(:noindex, true)
    |> put_resp_header("x-robots-tag", @value)
  end
end
