defmodule KanbanWeb.Plugs.PutNoindexTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias KanbanWeb.Plugs.PutNoindex

  defp call(conn), do: PutNoindex.call(conn, PutNoindex.init([]))

  test "init/1 returns the options unchanged" do
    assert PutNoindex.init([]) == []
  end

  test "assigns noindex and sets exactly one X-Robots-Tag value" do
    conn = call(conn(:get, "/"))

    assert conn.assigns.noindex == true
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "running twice still leaves one header value" do
    conn = conn(:get, "/") |> call() |> call()

    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "the header survives a halt with a redirect and a bodiless response" do
    redirected =
      conn(:get, "/")
      |> call()
      |> Phoenix.Controller.redirect(to: "/users/log-in")
      |> halt()

    assert redirected.status == 302
    assert get_resp_header(redirected, "x-robots-tag") == ["noindex, nofollow"]

    empty = conn(:post, "/") |> call() |> send_resp(400, "")

    assert empty.status == 400
    assert get_resp_header(empty, "x-robots-tag") == ["noindex, nofollow"]
  end
end
