defmodule KanbanWeb.TimezoneOnMountTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.LocalTime
  alias KanbanWeb.TimezoneOnMount
  alias Phoenix.LiveView.Socket

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  defp timezone_assign(view), do: :sys.get_state(view.pid).socket.assigns.timezone

  describe "on_mount/4" do
    test "defaults to UTC with no zone" do
      LocalTime.put_timezone("Europe/Paris")

      assert {:cont, socket} = TimezoneOnMount.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.timezone == "Etc/UTC"
      assert LocalTime.timezone() == "Etc/UTC"
    end

    test "uses the session zone on the static render" do
      session = %{"timezone" => "America/Edmonton"}

      assert {:cont, socket} = TimezoneOnMount.on_mount(:default, %{}, session, socket())
      assert socket.assigns.timezone == "America/Edmonton"
      assert LocalTime.timezone() == "America/Edmonton"
    end

    test "ignores an invalid session zone" do
      session = %{"timezone" => "Not/AZone"}

      assert {:cont, socket} = TimezoneOnMount.on_mount(:default, %{}, session, socket())
      assert socket.assigns.timezone == "Etc/UTC"
    end

    test "ignores an oversized session zone" do
      session = %{"timezone" => String.duplicate("A", 65)}

      assert {:cont, socket} = TimezoneOnMount.on_mount(:default, %{}, session, socket())
      assert socket.assigns.timezone == "Etc/UTC"
    end
  end

  describe "LocalTime.timezone/0" do
    test "returns Etc/UTC in a process where nothing was put" do
      task = Task.async(&LocalTime.timezone/0)

      assert Task.await(task) == "Etc/UTC"
    end
  end

  describe "in a live_session" do
    setup :register_and_log_in_user

    test "prefers the connect param when connected", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{timezone: "America/Edmonton"})
        |> put_connect_params(%{"timezone" => "America/Los_Angeles"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert timezone_assign(view) == "America/Los_Angeles"
    end

    test "uses the session zone when the connect param is invalid", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{timezone: "America/Edmonton"})
        |> put_connect_params(%{"timezone" => "Not/AZone"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert timezone_assign(view) == "America/Edmonton"
    end

    test "uses the session zone when the connect param is missing", %{conn: conn} do
      conn = init_test_session(conn, %{timezone: "America/Edmonton"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert timezone_assign(view) == "America/Edmonton"
    end

    test "a LiveView's static render uses the session zone in its markup", %{conn: conn} do
      # /metrics is under :require_authenticated_user and writes @timezone into
      # its export links, so the first byte must already carry the session zone.
      html =
        conn
        |> init_test_session(%{timezone: "America/New_York"})
        |> get(~p"/metrics")
        |> html_response(200)

      assert html =~ "timezone=America%2FNew_York"
      refute html =~ "timezone=Etc%2FUTC"
    end

    test "the static render reads the stride_tz cookie", %{conn: conn} do
      conn =
        conn
        |> put_req_cookie("stride_tz", "America%2FEdmonton")
        |> get(~p"/boards")

      assert html_response(conn, 200)
      assert get_session(conn, :timezone) == "America/Edmonton"
      assert LocalTime.timezone() == "America/Edmonton"
    end
  end

  test "every live_session runs the hook" do
    live_routes =
      for %{metadata: %{phoenix_live_view: {_view, _action, _opts, live_session}}} = route <-
            KanbanWeb.Router.__routes__(),
          do: {route.path, live_session}

    assert live_routes != []

    for {path, live_session} <- live_routes do
      hooks = Enum.map(live_session.extra.on_mount, & &1.id)

      assert {KanbanWeb.TimezoneOnMount, :default} in hooks,
             "#{path} is in a live_session without KanbanWeb.TimezoneOnMount"
    end
  end
end
