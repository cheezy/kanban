defmodule KanbanWeb.Plugs.TimezoneTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.LocalTime
  alias KanbanWeb.Plugs.Timezone

  defp run_plug(conn, cookie, session \\ %{}) do
    conn
    |> maybe_put_cookie(cookie)
    |> init_test_session(session)
    |> Timezone.call(Timezone.init([]))
  end

  defp maybe_put_cookie(conn, nil), do: conn
  defp maybe_put_cookie(conn, value), do: put_req_cookie(conn, "stride_tz", value)

  test "stores a valid cookie zone", %{conn: conn} do
    conn = run_plug(conn, "America%2FEdmonton")

    assert get_session(conn, :timezone) == "America/Edmonton"
    assert LocalTime.timezone() == "America/Edmonton"
  end

  test "rejects an oversized zone", %{conn: conn} do
    conn = run_plug(conn, String.duplicate("A", 65))

    assert get_session(conn, :timezone) == nil
    assert LocalTime.timezone() == "Etc/UTC"
  end

  test "rejects a cookie whose decoded zone exceeds the cap", %{conn: conn} do
    conn = run_plug(conn, "America%2F" <> String.duplicate("x", 60))

    assert get_session(conn, :timezone) == nil
    assert LocalTime.timezone() == "Etc/UTC"
  end

  test "falls back to UTC for an unknown zone", %{conn: conn} do
    conn = run_plug(conn, "Not%2FAZone")

    assert get_session(conn, :timezone) == nil
    assert LocalTime.timezone() == "Etc/UTC"
  end

  test "falls back to UTC for a malformed percent-encoding", %{conn: conn} do
    conn = run_plug(conn, "%zz")

    assert get_session(conn, :timezone) == nil
    assert LocalTime.timezone() == "Etc/UTC"
  end

  test "stores the zone as a string under :timezone", %{conn: conn} do
    conn = run_plug(conn, "US%2FEastern")

    assert get_session(conn) == %{"timezone" => "US/Eastern"}
    assert is_binary(get_session(conn, "timezone"))
  end

  test "decodes a zone with a plus sign", %{conn: conn} do
    # A literal "+" must stay a plus, not become a space as form decoding would.
    conn = run_plug(conn, "Etc%2FGMT+5")

    assert get_session(conn, :timezone) == "Etc/GMT+5"
    assert LocalTime.timezone() == "Etc/GMT+5"
  end

  test "uses the session zone when there is no cookie", %{conn: conn} do
    conn = run_plug(conn, nil, %{timezone: "Europe/Paris"})

    assert get_session(conn, :timezone) == "Europe/Paris"
    assert LocalTime.timezone() == "Europe/Paris"
  end

  test "keeps the session zone when the cookie is invalid", %{conn: conn} do
    conn = run_plug(conn, "Not%2FAZone", %{timezone: "Europe/Paris"})

    assert get_session(conn, :timezone) == "Europe/Paris"
    assert LocalTime.timezone() == "Europe/Paris"
  end

  test "ignores an invalid zone already in the session", %{conn: conn} do
    run_plug(conn, nil, %{timezone: "Not/AZone"})

    assert LocalTime.timezone() == "Etc/UTC"
  end

  test "the cookie replaces a different session zone", %{conn: conn} do
    conn = run_plug(conn, "America%2FEdmonton", %{timezone: "Europe/Paris"})

    assert get_session(conn, :timezone) == "America/Edmonton"
  end

  test "defaults to UTC with no cookie and no session zone", %{conn: conn} do
    LocalTime.put_timezone("Europe/Paris")
    conn = run_plug(conn, nil)

    assert get_session(conn, :timezone) == nil
    assert LocalTime.timezone() == "Etc/UTC"
  end

  describe "session writes" do
    # init_test_session/2 marks the session for writing itself, so clear that
    # mark to see whether the plug sets it.
    defp run_plug_unmarked(conn, cookie, session) do
      conn =
        conn
        |> put_req_cookie("stride_tz", cookie)
        |> init_test_session(session)

      conn
      |> Map.update!(:private, &Map.delete(&1, :plug_session_info))
      |> Timezone.call(Timezone.init([]))
    end

    test "does not rewrite the session when the cookie matches it", %{conn: conn} do
      conn = run_plug_unmarked(conn, "Europe%2FParis", %{timezone: "Europe/Paris"})

      refute Map.has_key?(conn.private, :plug_session_info)
    end

    test "marks the session for writing when the cookie zone is new", %{conn: conn} do
      conn = run_plug_unmarked(conn, "America%2FEdmonton", %{timezone: "Europe/Paris"})

      assert conn.private[:plug_session_info] == :write
    end
  end
end
