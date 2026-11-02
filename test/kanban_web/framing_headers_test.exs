defmodule KanbanWeb.FramingHeadersTest do
  # The browser pipeline's policy replaces Phoenix's default
  # "base-uri 'self'; frame-ancestors 'self';", and Phoenix 1.8 sends no
  # X-Frame-Options, so these pin that every HTML page still refuses to be
  # framed by another origin (clickjacking).
  use KanbanWeb.ConnCase, async: true

  defp framing(conn), do: get_resp_header(conn, "content-security-policy")

  test "the log-in page may only be framed by its own origin", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    assert conn.status == 200
    assert [policy] = framing(conn)
    assert policy =~ "frame-ancestors 'self'"
  end

  test "a signed-in page may only be framed by its own origin", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    conn = get(conn, ~p"/boards")

    assert conn.status == 200
    assert [policy] = framing(conn)
    assert policy =~ "frame-ancestors 'self'"
  end
end
