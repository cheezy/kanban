defmodule KanbanWeb.Plugs.CanonicalHitMePathTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  alias KanbanWeb.Plugs.CanonicalHitMePath

  defp call(method, path) do
    method
    |> conn(path)
    |> CanonicalHitMePath.call(CanonicalHitMePath.init([]))
  end

  defp assert_redirected(conn, location) do
    assert conn.status == 301
    assert conn.halted
    assert get_resp_header(conn, "location") == [location]
  end

  defp assert_passed_through(conn) do
    assert conn.status == nil
    refute conn.halted
    assert get_resp_header(conn, "location") == []
  end

  test "redirects GET /hitme to /HitMe with 301" do
    assert_redirected(call(:get, "/hitme"), "/HitMe")
  end

  test "redirects /HITME and /hItMe to /HitMe" do
    assert_redirected(call(:get, "/HITME"), "/HitMe")
    assert_redirected(call(:get, "/hItMe"), "/HitMe")
  end

  test "redirects HEAD /hitme to /HitMe" do
    assert_redirected(call(:head, "/hitme"), "/HitMe")
  end

  test "redirects /hitme/ with a trailing slash to /HitMe" do
    assert_redirected(call(:get, "/hitme/"), "/HitMe")
    assert_redirected(call(:get, "/HitMe/"), "/HitMe")
  end

  test "preserves the query string when redirecting, and adds none when there is none" do
    assert_redirected(call(:get, "/hitme?ref=flyer&lang=de"), "/HitMe?ref=flyer&lang=de")
    assert_redirected(call(:get, "/hitme?"), "/HitMe")
  end

  test "the location is always the fixed path, whatever the host" do
    conn =
      :get
      |> conn("https://evil.example.test/HITME?x=1")
      |> CanonicalHitMePath.call([])

    assert_redirected(conn, "/HitMe?x=1")
  end

  test "leaves GET /HitMe untouched" do
    assert_passed_through(call(:get, "/HitMe"))
    assert_passed_through(call(:get, "/HitMe?ref=flyer"))
  end

  test "leaves unrelated paths such as /pricing and /hitmeplease untouched" do
    for path <- ["/", "/pricing", "/hitmeplease", "/hitme/more", "/x/hitme", "/hit-me"] do
      assert_passed_through(call(:get, path))
    end
  end

  test "does not redirect POST /hitme" do
    for method <- [:post, :put, :patch, :delete] do
      assert_passed_through(call(method, "/hitme"))
    end
  end
end

defmodule KanbanWeb.Plugs.CanonicalHitMePathEndpointTest do
  use KanbanWeb.ConnCase, async: true

  test "GET /hitme through the endpoint redirects to /HitMe, and following it renders the HitMe page",
       %{conn: conn} do
    location = conn |> get("/hitme?ref=flyer") |> redirected_to(301)

    assert location == "/HitMe?ref=flyer"

    body = build_conn() |> get(location) |> html_response(200)
    assert body |> LazyHTML.from_document() |> LazyHTML.query("#hitme-hero") |> Enum.count() == 1
  end

  test "POST /hitme through the endpoint is not redirected", %{conn: conn} do
    conn = post(conn, "/hitme")

    assert conn.status == 404
    assert get_resp_header(conn, "location") == []
  end
end
