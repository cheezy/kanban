defmodule KanbanWeb.AuditLogExportControllerTest do
  # async: false — tests assert on audit_events rows, a shared table.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  defp insert_event!(action, inserted_at, metadata) do
    Repo.insert!(%AuditEvent{action: action, inserted_at: inserted_at, metadata: metadata})
  end

  @export_headers ["content-type", "content-disposition", "cache-control"]

  defp export_headers(conn), do: Map.new(@export_headers, &{&1, get_resp_header(conn, &1)})

  # Every query this test process sent to audit_events since the handler was
  # attached, drained from the mailbox.
  defp audit_event_queries(acc \\ []) do
    receive do
      {:telemetry_event, [:kanban, :repo, :query], _measurements,
       %{source: "audit_events"} = meta} ->
        audit_event_queries([meta | acc])

      {:telemetry_event, [:kanban, :repo, :query], _measurements, _other} ->
        audit_event_queries(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "as a site admin" do
    setup %{conn: conn} do
      admin = admin_fixture()

      insert_event!("login_failed", ~U[2026-10-01 00:00:00.000000Z], %{"email" => "=evil()"})

      insert_event!("sudo_mode_entered", ~U[2026-10-02 00:00:00.000000Z], %{
        "note" => "line1\nline2, \"quoted\" ✓"
      })

      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "defaults to a CSV attachment with a safe filename", %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/csv"

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/\Aattachment; filename="audit_log_\d{4}-\d{2}-\d{2}\.csv"\z/
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      body = response(conn, 200)

      assert String.starts_with?(
               body,
               "id,inserted_at,action,actor_user_id,actor_email,ip,metadata\r\n"
             )

      assert body =~ ",login_failed,"
      assert body =~ ",sudo_mode_entered,"
    end

    test "exports JSON as a valid array of objects with metadata intact", %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export?format=json")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/filename="audit_log_\d{4}-\d{2}-\d{2}\.json"/

      rows = conn |> response(200) |> Jason.decode!()

      assert Enum.all?(rows, &is_map/1)

      assert %{"metadata" => %{"note" => "line1\nline2, \"quoted\" ✓"}} =
               Enum.find(rows, &(&1["action"] == "sudo_mode_entered"))
    end

    test "export emits the export span without filters", %{conn: conn} do
      attach_telemetry([[:kanban, :export, :start], [:kanban, :export, :stop]])

      conn = get(conn, ~p"/admin/audit-log/export?format=json&action=login_failed")
      assert conn.status == 200

      assert_receive {:telemetry_event, [:kanban, :export, :start], _, start}
      assert_receive {:telemetry_event, [:kanban, :export, :stop], %{duration: _}, stop}

      # Only the kind and format: never the filters, the admin or an IP address.
      for metadata <- [start, stop] do
        assert Map.delete(metadata, :telemetry_span_context) == %{kind: :audit_log, format: :json}
      end
    end

    test "honours the viewer's filters", %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export?format=json&action=login_failed&to=2026-10-01")

      assert [%{"action" => "login_failed", "metadata" => %{"email" => "=evil()"}}] =
               conn |> response(200) |> Jason.decode!()
    end

    test "records an audit_log_exported event with the admin, format and filters",
         %{conn: conn, admin: admin} do
      get(conn, ~p"/admin/audit-log/export?format=json&action=login_failed&cursor=junk")

      assert [%AuditEvent{actor_user_id: actor_id, metadata: metadata}] =
               AuditLog.list_events(action: :audit_log_exported)

      assert actor_id == admin.id
      assert metadata["format"] == "json"
      assert metadata["filters"] == %{"action" => "login_failed"}
    end

    test "an out-of-range year is ignored instead of truncating the export", %{conn: conn} do
      rows =
        conn
        |> get(~p"/admin/audit-log/export?format=json&from=-4713-01-01")
        |> response(200)
        |> Jason.decode!()

      assert Enum.any?(rows, &(&1["action"] == "login_failed"))
      assert Enum.any?(rows, &(&1["action"] == "sudo_mode_entered"))
    end

    test "neutralises formula cells in the CSV", %{conn: conn} do
      insert_event!("=HYPERLINK(1)", ~U[2026-10-03 00:00:00.000000Z], %{})

      body = conn |> get(~p"/admin/audit-log/export?format=csv") |> response(200)

      assert body =~ ",'=HYPERLINK(1),"
      refute body =~ ~r/(\A|,)=HYPERLINK/
    end

    test "an unsupported format redirects back with a flash and exports nothing",
         %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export?format=xlsx")

      assert redirected_to(conn) == ~p"/admin/audit-log"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unsupported export format"
      assert AuditLog.list_events(action: :audit_log_exported) == []
    end

    test "HEAD /admin/audit-log/export answers 200 with the same content-type, content-disposition and cache-control as GET and no body",
         %{conn: conn} do
      for path <- [
            ~p"/admin/audit-log/export",
            ~p"/admin/audit-log/export?format=csv",
            ~p"/admin/audit-log/export?format=json&action=login_failed&to=2026-10-01"
          ] do
        got = get(conn, path)
        headed = head(conn, path)

        assert got.status == 200
        assert response(headed, 200) == ""
        assert export_headers(headed) == export_headers(got)
        assert [_content_type] = get_resp_header(headed, "content-type")
      end
    end

    test "HEAD /admin/audit-log/export writes no audit_log_exported row", %{conn: conn} do
      head(conn, ~p"/admin/audit-log/export?format=csv")
      head(conn, ~p"/admin/audit-log/export?format=json&action=login_failed")

      assert AuditLog.list_events(action: :audit_log_exported) == []
    end

    test "HEAD /admin/audit-log/export reads and writes nothing in audit_events", %{conn: conn} do
      attach_telemetry([:kanban, :repo, :query])

      assert conn |> head(~p"/admin/audit-log/export?format=json") |> response(200) == ""
      assert audit_event_queries() == []

      # The same probe sees a GET read the table and write its row, so the
      # empty result above is not a probe that cannot see anything.
      assert conn |> get(~p"/admin/audit-log/export?format=json") |> response(200)
      assert length(audit_event_queries()) >= 2
    end

    test "HEAD /admin/audit-log/export emits no [:kanban, :export, :stop] event", %{conn: conn} do
      attach_telemetry([[:kanban, :export, :start], [:kanban, :export, :stop]])

      assert conn |> head(~p"/admin/audit-log/export?format=csv") |> response(200) == ""

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
      refute_received {:telemetry_event, [:kanban, :export, :stop], _, _}
    end

    test "HEAD /admin/audit-log/export?format=xml is refused with the same redirect and flash as GET",
         %{conn: conn} do
      got = get(conn, ~p"/admin/audit-log/export?format=xml")
      headed = head(conn, ~p"/admin/audit-log/export?format=xml")

      assert redirected_to(headed) == redirected_to(got)
      assert redirected_to(headed) == ~p"/admin/audit-log"

      assert Phoenix.Flash.get(headed.assigns.flash, :error) ==
               Phoenix.Flash.get(got.assigns.flash, :error)

      assert Phoenix.Flash.get(headed.assigns.flash, :error) =~ "Unsupported export format"
      assert AuditLog.list_events(action: :audit_log_exported) == []
    end

    test "GET /admin/audit-log/export still writes exactly one audit_log_exported row and emits the export span",
         %{conn: conn, admin: admin} do
      attach_telemetry([[:kanban, :export, :stop]])

      assert conn |> get(~p"/admin/audit-log/export?format=csv") |> response(200)

      assert [%AuditEvent{actor_user_id: actor_id}] =
               AuditLog.list_events(action: :audit_log_exported)

      assert actor_id == admin.id

      assert_received {:telemetry_event, [:kanban, :export, :stop], _,
                       %{kind: :audit_log, format: :csv}}
    end
  end

  describe "access control" do
    test "a non-admin is redirected to / and permission_denied is recorded", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/admin/audit-log/export?format=json")

      assert redirected_to(conn) == ~p"/"

      assert [%AuditEvent{actor_user_id: actor_id, metadata: metadata}] =
               AuditLog.list_events(action: :permission_denied)

      assert actor_id == user.id
      assert metadata["gate"] == "require_admin_user"
      assert AuditLog.list_events(action: :audit_log_exported) == []
    end

    test "a HEAD by a non-admin is refused exactly as a GET is", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> head(~p"/admin/audit-log/export?format=json")

      assert redirected_to(conn) == ~p"/"
      assert [%AuditEvent{}] = AuditLog.list_events(action: :permission_denied)
      assert AuditLog.list_events(action: :audit_log_exported) == []
    end

    test "an unauthenticated visitor is sent to log in", %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
