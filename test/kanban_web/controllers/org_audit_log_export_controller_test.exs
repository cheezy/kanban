defmodule KanbanWeb.OrgAuditLogExportControllerTest do
  # async: false — the row-cap and rate-limit tests change application env
  # (Kanban.RateLimit and this controller's max_rows).
  use KanbanWeb.ConnCase, async: false

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

  @rate_limit 2
  @max_rows 3

  # Turns Kanban.RateLimit on (the suite runs with it off) and lowers the row
  # cap; each test uses fresh users, so the shared bucket store cannot bleed
  # state between tests.
  defp limits_setup(%{conn: conn}) do
    original_rate_limit = Application.get_env(:kanban, Kanban.RateLimit)
    original_export = Application.get_env(:kanban, KanbanWeb.OrgAuditLogExportController)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      org_audit_export: %{scale_ms: 60_000, id_limit: @rate_limit}
    )

    Application.put_env(:kanban, KanbanWeb.OrgAuditLogExportController, max_rows: @max_rows)

    on_exit(fn ->
      Application.put_env(:kanban, Kanban.RateLimit, original_rate_limit)
      restore(KanbanWeb.OrgAuditLogExportController, original_export)
    end)

    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), organization: organization, org_admin: org_admin}
  end

  defp restore(key, nil), do: Application.delete_env(:kanban, key)
  defp restore(key, value), do: Application.put_env(:kanban, key, value)

  defp insert_cap_events!(organization, count) do
    for i <- 1..count//1 do
      Repo.insert!(%AuditEvent{
        action: "organization_updated",
        organization_id: organization.id,
        inserted_at: DateTime.add(~U[2026-10-01 00:00:00.000000Z], i),
        metadata: %{}
      })
    end
  end

  defp export_events, do: AuditLog.list_events(action: :org_audit_log_exported)

  describe "row cap" do
    setup :limits_setup

    test "export under the cap is not truncated", %{conn: conn, organization: organization} do
      # One existing row plus the export's own row: two of three places.
      insert_cap_events!(organization, 1)

      conn = get(conn, ~p"/org/audit/export?format=json")

      assert get_resp_header(conn, "x-export-truncated") == []

      assert conn |> response(200) |> Jason.decode!() |> Enum.map(& &1["action"]) ==
               ["org_audit_log_exported", "organization_updated"]

      assert [event] = export_events()
      assert event.metadata["truncated"] == false
    end

    test "exactly max_rows rows, counting the export's own row, is not truncated",
         %{conn: conn, organization: organization} do
      insert_cap_events!(organization, @max_rows - 1)

      conn = get(conn, ~p"/org/audit/export?format=json")

      assert get_resp_header(conn, "x-export-truncated") == []
      assert conn |> response(200) |> Jason.decode!() |> length() == @max_rows
      assert [%{metadata: %{"truncated" => false}}] = export_events()
    end

    test "exactly max_rows matching rows the export's own row does not match is not truncated",
         %{conn: conn, organization: organization} do
      insert_cap_events!(organization, @max_rows)

      conn = get(conn, ~p"/org/audit/export?format=json&action=organization_updated")

      assert get_resp_header(conn, "x-export-truncated") == []
      assert conn |> response(200) |> Jason.decode!() |> length() == @max_rows
      assert [%{metadata: %{"truncated" => false}}] = export_events()
    end

    test "export over the cap is marked truncated", %{conn: conn, organization: organization} do
      insert_cap_events!(organization, @max_rows)

      for format <- ["csv", "json"] do
        conn = get(conn, ~p"/org/audit/export?format=#{format}")

        assert get_resp_header(conn, "x-export-truncated") == ["true"]
        body = response(conn, 200)

        case format do
          "csv" ->
            assert [_header | rows] = String.split(body, "\r\n", trim: true)
            assert length(rows) == @max_rows

          "json" ->
            # Still one valid array, newest first, led by the export's own row.
            assert [%{"action" => "org_audit_log_exported"} | _] = rows = Jason.decode!(body)
            assert length(rows) == @max_rows
        end
      end

      assert [_, _] = events = export_events()
      assert Enum.all?(events, &(&1.metadata["truncated"] == true))
    end

    test "a date range that ends before today does not count the export's own row",
         %{conn: conn, organization: organization} do
      insert_cap_events!(organization, @max_rows)

      conn = get(conn, ~p"/org/audit/export?format=json&from=2026-10-01&to=2026-10-01")

      assert get_resp_header(conn, "x-export-truncated") == []
      assert conn |> response(200) |> Jason.decode!() |> length() == @max_rows
    end

    test "the truncation telemetry carries only the boolean", %{conn: conn, organization: org} do
      attach_telemetry([[:kanban, :audit, :org_audit_log_exported]])
      insert_cap_events!(org, @max_rows)

      get(conn, ~p"/org/audit/export?format=json&action=organization_updated")

      assert_receive {:telemetry_event, [:kanban, :audit, :org_audit_log_exported], _, metadata}
      assert metadata.truncated == false
      refute Map.has_key?(metadata, :filters)
      refute Map.has_key?(metadata, :ip)
    end
  end

  describe "rate limit" do
    setup :limits_setup

    test "rate-limited export writes nothing", %{conn: conn} do
      attach_telemetry([[:kanban, :export, :start], [:kanban, :rate_limit, :denied]])

      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export?format=json") |> response(200)
      end

      assert_receive {:telemetry_event, [:kanban, :export, :start], _, _}
      assert_receive {:telemetry_event, [:kanban, :export, :start], _, _}
      assert length(export_events()) == @rate_limit

      refused = get(conn, ~p"/org/audit/export?format=json")

      assert redirected_to(refused) == ~p"/org/audit"

      assert Phoenix.Flash.get(refused.assigns.flash, :error) ==
               "Too many exports. Try again later."

      # No audit row, and no export span: the stream was never opened.
      assert length(export_events()) == @rate_limit

      assert_receive {:telemetry_event, [:kanban, :rate_limit, :denied], _,
                      %{surface: :org_audit_export}}

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
    end

    # Concurrent requests from one org-admin: separate conns (each its own
    # session token) sharing the user, released together by a barrier. The
    # sandbox is in shared mode (async: false), so every request process
    # reaches the same database connection. Kanban.RateLimit counts with an
    # atomic ETS update, so exactly @rate_limit requests win however they
    # interleave.
    @concurrent_exports 8

    test "concurrent exports from one org-admin never exceed the limit and refused ones write nothing",
         %{organization: organization, org_admin: org_admin} do
      attach_telemetry([[:kanban, :export, :start], [:kanban, :rate_limit, :denied]])
      insert_cap_events!(organization, 1)

      conns = for _ <- 1..@concurrent_exports, do: log_in_user(build_conn(), org_admin)

      tasks =
        for conn <- conns do
          Task.async(fn ->
            receive do
              :go -> get(conn, ~p"/org/audit/export?format=json")
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks, 30_000)

      {served, refused} = Enum.split_with(results, &(&1.status == 200))

      assert length(served) == @rate_limit
      assert length(refused) == @concurrent_exports - @rate_limit

      for conn <- served do
        assert [%{"action" => "org_audit_log_exported"} | _] =
                 conn |> response(200) |> Jason.decode!()
      end

      for conn <- refused do
        assert redirected_to(conn) == ~p"/org/audit"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Too many exports. Try again later."
      end

      # One audit row per served export and none for a refused one.
      assert [_, _] = events = export_events()
      assert Enum.all?(events, &(&1.actor_user_id == org_admin.id))

      for _ <- 1..@rate_limit,
          do: assert_receive({:telemetry_event, [:kanban, :export, :start], _, _})

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}

      for _ <- 1..(@concurrent_exports - @rate_limit) do
        assert_receive {:telemetry_event, [:kanban, :rate_limit, :denied], _,
                        %{surface: :org_audit_export}}
      end

      # A later, sequential request is still refused: the window is spent.
      assert conns |> hd() |> get(~p"/org/audit/export") |> redirected_to() == ~p"/org/audit"
      assert length(export_events()) == @rate_limit
    end

    test "limit is per org-admin", %{conn: conn, organization: organization} do
      for _ <- 1..@rate_limit, do: get(conn, ~p"/org/audit/export")
      assert conn |> get(~p"/org/audit/export") |> redirected_to() == ~p"/org/audit"

      colleague = user_fixture()
      organization_member_fixture(organization, colleague, :org_admin)

      other =
        build_conn()
        |> log_in_user(colleague)
        |> get(~p"/org/audit/export")

      assert response(other, 200)
    end

    test "varying the params does not reset the limit", %{conn: conn} do
      get(conn, ~p"/org/audit/export?format=csv")
      get(conn, ~p"/org/audit/export?format=json&action=organization_updated")

      refused = get(conn, ~p"/org/audit/export?format=csv&from=2026-01-01&user_id=999")

      assert redirected_to(refused) == ~p"/org/audit"
    end

    test "an unsupported format is refused without charging the limit", %{conn: conn} do
      for _ <- 1..5 do
        refused = get(conn, ~p"/org/audit/export?format=xml")
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Unsupported export format."
      end

      assert conn |> get(~p"/org/audit/export?format=json") |> response(200)
      assert export_events() |> length() == 1
    end
  end
end
