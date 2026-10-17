defmodule KanbanWeb.OrgAuditLogExportControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  @refusal "You must be an org-admin of an Organization to access this page."

  defp insert_event!(action, organization, inserted_at, metadata \\ %{}) do
    Repo.insert!(%AuditEvent{
      action: action,
      organization_id: organization && organization.id,
      inserted_at: inserted_at,
      metadata: metadata
    })
  end

  defp org_admin_setup(%{conn: conn}) do
    org_a = organization_fixture()
    org_b = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org_a, org_admin, :org_admin)

    insert_event!("organization_updated", org_a, ~U[2026-10-01 00:00:00.000000Z], %{
      "note" => "a, \"quoted\" ✓"
    })

    insert_event!("org_admin_appointed", org_a, ~U[2026-10-02 00:00:00.000000Z])
    insert_event!("organization_created", org_b, ~U[2026-10-03 00:00:00.000000Z])
    insert_event!("login_failed", nil, ~U[2026-10-04 00:00:00.000000Z])

    %{conn: log_in_user(conn, org_admin), org_a: org_a, org_b: org_b, org_admin: org_admin}
  end

  defp exported_actions(conn) do
    conn
    |> response(200)
    |> Jason.decode!()
    |> Enum.map(& &1["action"])
  end

  describe "as an org-admin" do
    setup :org_admin_setup

    test "defaults to a CSV attachment holding only the Organization's events", %{conn: conn} do
      conn = get(conn, ~p"/org/audit/export")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/csv"
      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~
               ~r/\Aattachment; filename="org_audit_log_\d{4}-\d{2}-\d{2}\.csv"\z/

      assert get_resp_header(conn, "cache-control") == ["no-store"]

      body = response(conn, 200)
      assert body =~ ",organization_updated,"
      assert body =~ ",org_admin_appointed,"
      refute body =~ "organization_created"
      refute body =~ "login_failed"
    end

    test "exports JSON for the Organization only, with metadata intact", %{conn: conn} do
      conn = get(conn, ~p"/org/audit/export?format=json")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      rows = conn |> response(200) |> Jason.decode!()

      # The export is recorded before the first byte, so it leads its own file.
      assert Enum.map(rows, & &1["action"]) ==
               ["org_audit_log_exported", "org_admin_appointed", "organization_updated"]

      assert %{"metadata" => %{"note" => "a, \"quoted\" ✓"}} =
               Enum.find(rows, &(&1["action"] == "organization_updated"))
    end

    test "an organization_id param cannot widen the export", %{conn: conn, org_b: org_b} do
      conn = get(conn, ~p"/org/audit/export?format=json&organization_id=#{org_b.id}")

      assert exported_actions(conn) ==
               ["org_audit_log_exported", "org_admin_appointed", "organization_updated"]
    end

    test "applies the viewer's filters inside the Organization", %{conn: conn} do
      conn = get(conn, ~p"/org/audit/export?format=json&action=org_admin_appointed")
      assert exported_actions(conn) == ["org_admin_appointed"]
    end

    test "records :org_audit_log_exported with organization_id before streaming",
         %{conn: conn, org_a: org_a, org_admin: org_admin} do
      get(conn, ~p"/org/audit/export?format=json&action=org_admin_appointed")

      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.actor_user_id == org_admin.id
      assert event.organization_id == org_a.id

      assert event.metadata["filters"] == %{"action" => "org_admin_appointed"}
      assert event.metadata["format"] == "json"
      assert event.metadata["organization_id"] == org_a.id
    end

    test "a recorded export belongs to the Organization and appears in its next export",
         %{conn: conn} do
      get(conn, ~p"/org/audit/export?format=json")
      second = get(conn, ~p"/org/audit/export?format=json")

      assert ["org_audit_log_exported" | _] = exported_actions(second)
    end

    test "emits the export span with kind :org_audit_log and no filters", %{conn: conn} do
      attach_telemetry([[:kanban, :export, :start], [:kanban, :export, :stop]])

      conn = get(conn, ~p"/org/audit/export?format=json&action=login_failed")
      assert conn.status == 200

      assert_receive {:telemetry_event, [:kanban, :export, :start], _, start}
      assert_receive {:telemetry_event, [:kanban, :export, :stop], %{duration: _}, stop}

      for metadata <- [start, stop] do
        assert Map.delete(metadata, :telemetry_span_context) == %{
                 kind: :org_audit_log,
                 format: :json
               }
      end
    end

    test "never exports a site admin actor's email or IP", %{conn: conn, org_a: org_a} do
      site_admin = admin_fixture()

      Repo.insert!(%AuditEvent{
        action: "organization_updated",
        organization_id: org_a.id,
        actor_user_id: site_admin.id,
        ip: "203.0.113.9",
        inserted_at: ~U[2026-10-05 00:00:00.000000Z],
        metadata: %{"user_id" => site_admin.id, "ip" => "203.0.113.9"}
      })

      for format <- ["csv", "json"] do
        body = conn |> get(~p"/org/audit/export?format=#{format}") |> response(200)

        refute body =~ site_admin.email
        refute body =~ "203.0.113.9"
      end
    end

    test "ignores an actor_email param, so a guessed staff email confirms nothing", %{
      conn: conn,
      org_a: org_a
    } do
      site_admin = admin_fixture()

      Repo.insert!(%AuditEvent{
        action: "organization_updated",
        organization_id: org_a.id,
        actor_user_id: site_admin.id,
        inserted_at: ~U[2026-10-05 00:00:00.000000Z],
        metadata: %{}
      })

      conn =
        get(
          conn,
          ~p"/org/audit/export?#{%{"format" => "json", "actor_email" => site_admin.email}}"
        )

      assert exported_actions(conn) ==
               [
                 "org_audit_log_exported",
                 "organization_updated",
                 "org_admin_appointed",
                 "organization_updated"
               ]

      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.metadata["filters"] == %{}
    end

    test "exports a member actor's email", %{conn: conn, org_admin: org_admin} do
      conn = get(conn, ~p"/org/audit/export?format=json")

      assert %{"actor_email" => email} =
               conn |> response(200) |> Jason.decode!() |> hd()

      assert email == org_admin.email
    end

    test "an unsupported format redirects back to the viewer", %{conn: conn} do
      conn = get(conn, ~p"/org/audit/export?format=xml")

      assert redirected_to(conn) == ~p"/org/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unsupported export format."
      assert AuditLog.list_events(action: :org_audit_log_exported) == []
    end
  end

  describe "access control" do
    test "a member is refused and the refusal is audited", %{conn: conn} do
      member = user_fixture()
      organization_member_fixture(organization_fixture(), member, :member)

      conn = conn |> log_in_user(member) |> get(~p"/org/audit/export")

      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
      assert event.metadata["gate"] == "require_org_admin"
      assert AuditLog.list_events(action: :org_audit_log_exported) == []
    end

    test "a free user in no Organization is refused", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/org/audit/export")

      assert redirected_to(conn) == ~p"/boards"
    end

    test "a site admin is refused", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get(~p"/org/audit/export")

      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
    end

    test "an unauthenticated visitor is sent to log in" do
      conn = get(build_conn(), ~p"/org/audit/export")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
