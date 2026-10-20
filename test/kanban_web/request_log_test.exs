defmodule KanbanWeb.RequestLogTest do
  # async: false - the tests lower the global Logger level to :debug.
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Kanban.Workspaces.Invitation
  alias KanbanWeb.RequestLog

  # Logs everything this process emits, debug included, so a token anywhere in
  # the request's log output (the request line, the router's parameters, the
  # LiveView mount) is caught.
  defp capture_all(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    capture_log([level: :debug], fun)
  end

  describe "the request log" do
    test "never contains an invitation link's token", %{conn: conn} do
      {token, _hash} = Invitation.build_token()

      log = capture_all(fn -> get(conn, ~p"/invitations/#{token}") end)

      refute log =~ token
      assert log =~ "GET /invitations/[FILTERED]"
      assert log =~ ~r/Sent \d{3} in /
    end

    test "never contains the token through a connected LiveView visit either", %{conn: conn} do
      {token, _hash} = Invitation.build_token()

      log = capture_all(fn -> {:ok, _view, _html} = live(conn, ~p"/invitations/#{token}") end)

      refute log =~ token
      assert log =~ "MOUNT KanbanWeb.WorkspaceLive.InvitationAccept"
    end

    test "never contains a password reset token", %{conn: conn} do
      token = "resettoken#{System.unique_integer([:positive])}"

      log = capture_all(fn -> get(conn, "/users/reset-password/#{token}") end)

      refute log =~ token
      assert log =~ "GET /users/reset-password/[FILTERED]"
    end

    test "still logs other requests' paths as Phoenix does", %{conn: conn} do
      log = capture_all(fn -> get(conn, ~p"/users/log-in") end)

      assert log =~ "GET /users/log-in"
      assert log =~ ~r/Sent 200 in /
    end
  end

  describe "level/1" do
    test "is false on a token route and :info elsewhere" do
      refute RequestLog.level(%Plug.Conn{request_path: "/invitations/abc"})
      refute RequestLog.level(%Plug.Conn{request_path: "/users/confirm/abc"})
      assert RequestLog.level(%Plug.Conn{request_path: "/boards"}) == :info
      assert RequestLog.level(%Plug.Conn{request_path: "/invitations/"}) == :info
    end
  end

  describe "attach/0" do
    test "is attached when the app starts, and attaching again is a no-op" do
      handler_ids =
        [:phoenix, :endpoint, :start] |> :telemetry.list_handlers() |> Enum.map(& &1.id)

      assert {RequestLog, :redacted_request_lines} in handler_ids
      assert RequestLog.attach() == :ok
    end
  end

  describe "handle_event/4" do
    test "logs nothing for other routes and ignores other events" do
      conn = %Plug.Conn{method: "GET", request_path: "/boards", status: 200}
      start = [:phoenix, :endpoint, :start]
      stop = [:phoenix, :endpoint, :stop]

      log =
        capture_all(fn ->
          assert :ok = RequestLog.handle_event(start, %{}, %{conn: conn}, nil)
          assert :ok = RequestLog.handle_event(stop, %{duration: 1}, %{conn: conn}, nil)
          assert :ok = RequestLog.handle_event([:other], %{}, %{}, nil)
        end)

      assert log == ""
    end

    test "logs a token route's stop line, without a status as a dash" do
      conn = %Plug.Conn{method: "GET", request_path: "/invitations/abc", status: nil}
      stop = [:phoenix, :endpoint, :stop]

      log =
        capture_all(fn -> RequestLog.handle_event(stop, %{duration: 1}, %{conn: conn}, nil) end)

      assert log =~ "Sent - in "
      refute log =~ "abc"
    end
  end

  describe "format_duration/1" do
    test "uses microseconds up to a millisecond and milliseconds above" do
      native = &System.convert_time_unit(&1, :microsecond, :native)

      assert 250 |> native.() |> RequestLog.format_duration() == "250µs"
      assert 1000 |> native.() |> RequestLog.format_duration() == "1000µs"
      assert 4_500 |> native.() |> RequestLog.format_duration() == "4ms"
    end
  end
end
