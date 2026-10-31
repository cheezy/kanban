defmodule KanbanWeb.Plugs.CanonicalHitMePath do
  @moduledoc """
  Redirects every casing of `/hitme` to the canonical `/HitMe` page with a 301.

  The printed handout gives the address as `StrideLikeABoss.com/HitMe`, and
  people often retype it in lower case. Phoenix routes are case-sensitive, so
  `/hitme` would 404. No route matches the miscased path, so the router's
  pipelines never run for it: this plug sits in `KanbanWeb.Endpoint`,
  immediately before the router.

  Only a GET or HEAD whose path, ignoring case and a trailing slash, is
  `/hitme` is redirected, and never `/HitMe` itself. The location is always
  the fixed path `/HitMe` plus the original query string, never anything taken
  from the Host header or the requested path. Every other request passes
  through untouched.
  """

  import Plug.Conn, only: [put_resp_header: 3, send_resp: 3, halt: 1]

  @canonical_path "/HitMe"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%Plug.Conn{method: method, path_info: [segment]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    if String.downcase(segment) == "hitme" and conn.request_path != @canonical_path,
      do: redirect_to_canonical(conn),
      else: conn
  end

  def call(conn, _opts), do: conn

  defp redirect_to_canonical(conn) do
    conn
    |> put_resp_header("location", location(conn.query_string))
    |> send_resp(301, "")
    |> halt()
  end

  defp location(""), do: @canonical_path
  defp location(query_string), do: @canonical_path <> "?" <> query_string
end
