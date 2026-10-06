defmodule KanbanWeb.AuditLogExportControllerTest do
  # async: false — tests assert on audit_events rows, a shared table.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  defp insert_event!(action, inserted_at, metadata) do
    Repo.insert!(%AuditEvent{action: action, inserted_at: inserted_at, metadata: metadata})
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

    test "an unauthenticated visitor is sent to log in", %{conn: conn} do
      conn = get(conn, ~p"/admin/audit-log/export")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
