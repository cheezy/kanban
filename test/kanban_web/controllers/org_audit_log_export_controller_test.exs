defmodule KanbanWeb.OrgAuditLogExportControllerTest do
  # async: false — the row-cap and rate-limit tests change application env
  # (Kanban.RateLimit and this controller's max_rows), and the signed-export
  # tests change Kanban.AuditLog.SignedExport's and Kanban.AuditLog.Signing's.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.SignedExport
  alias Kanban.AuditLog.Signing
  alias Kanban.Organizations
  alias Kanban.Repo
  alias KanbanWeb.ClosingSendFileAdapter
  alias KanbanWeb.OrgAuditLogExportController

  @refusal "You must be an org-admin of an Organization to access this page."

  @invalid_signed "The signed parameter must be true or false."

  # Values that are neither absent, "false" nor the exact "true": each is
  # refused rather than read as a request for an unsigned file.
  @invalid_signed_queries [
    "signed=yes",
    "signed=1",
    "signed=0",
    "signed=TRUE",
    "signed=True",
    "signed=",
    "signed",
    "signed=%20true",
    "signed=true%20",
    "signed=yes&format=json"
  ]

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

    # /org/audit drops an action filter its Action select does not offer, so
    # the same URL params must give the same rows in the export.
    test "an unknown action is dropped from the unsigned CSV and JSON exports and from the recorded filters",
         %{conn: conn} do
      json = get(conn, ~p"/org/audit/export?format=json&action=bogus_action")

      assert exported_actions(json) ==
               ["org_audit_log_exported", "org_admin_appointed", "organization_updated"]

      csv = conn |> get(~p"/org/audit/export?format=csv&action=bogus_action") |> response(200)
      assert csv =~ ",org_audit_log_exported,"
      assert csv =~ ",org_admin_appointed,"
      assert csv =~ ",organization_updated,"

      events = export_events()
      assert length(events) == 2
      assert Enum.all?(events, &(&1.metadata["filters"] == %{}))
    end

    test "an unknown action is dropped but the date filters still apply", %{conn: conn} do
      conn =
        get(conn, ~p"/org/audit/export?format=json&action=bogus_action&to=2026-10-01")

      assert exported_actions(conn) == ["organization_updated"]
      assert [event] = export_events()
      assert event.metadata["filters"] == %{"to" => "2026-10-01"}
    end

    test "an action only another Organization holds is dropped from the export", %{conn: conn} do
      # organization_created is an event of org_b only.
      conn = get(conn, ~p"/org/audit/export?format=json&action=organization_created")

      assert exported_actions(conn) ==
               ["org_audit_log_exported", "org_admin_appointed", "organization_updated"]

      assert [event] = export_events()
      assert event.metadata["filters"] == %{}
    end

    test "org_audit_log_exported is dropped until the Organization has recorded one, as on the page",
         %{conn: conn} do
      first = get(conn, ~p"/org/audit/export?format=json&action=org_audit_log_exported")

      assert exported_actions(first) ==
               ["org_audit_log_exported", "org_admin_appointed", "organization_updated"]

      # Now this Organization holds the action, so the filter is applied.
      second = get(conn, ~p"/org/audit/export?format=json&action=org_audit_log_exported")

      assert exported_actions(second) == ["org_audit_log_exported", "org_audit_log_exported"]

      assert export_events() |> Enum.map(& &1.metadata["filters"]) |> Enum.sort() ==
               [%{}, %{"action" => "org_audit_log_exported"}]
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

    test "the unsigned export event carries signed false and no key or hash", %{conn: conn} do
      for query <- ["", "?format=json", "?signed=false"] do
        conn = get(conn, "/org/audit/export" <> query)

        assert [content_type] = get_resp_header(conn, "content-type")
        refute content_type =~ "zip"
        assert response(conn, 200)
      end

      assert [_, _, _] = events = AuditLog.list_events(action: :org_audit_log_exported)

      for event <- events do
        assert event.metadata["signed"] == false
        refute Map.has_key?(event.metadata, "key_id")
        refute Map.has_key?(event.metadata, "sha256")
      end
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

  ## Signed exports

  defp signed_setup(%{tmp_dir: tmp_dir}) do
    saved = Enum.map([SignedExport, Signing], &{&1, Application.fetch_env(:kanban, &1)})
    Application.put_env(:kanban, SignedExport, tmp_root: tmp_dir)
    on_exit(fn -> Enum.each(saved, &restore_env/1) end)

    %{root: tmp_dir}
  end

  defp restore_env({module, {:ok, config}}), do: Application.put_env(:kanban, module, config)
  defp restore_env({module, :error}), do: Application.delete_env(:kanban, module)

  defp unzip(conn) do
    {:ok, entries} = conn |> response(200) |> :zip.unzip([:memory])
    Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp unsigned_file(organization, format, max_rows) do
    [organization_id: organization.id]
    |> Export.export_stream(format, max_rows: max_rows, redact_actors_outside: organization.id)
    |> Enum.join()
  end

  # The signature over the manifest verifies with the published key, and the
  # manifest's hash and size are those of the file beside it.
  defp assert_verifies(entries, file_name) do
    manifest_bytes = entries["manifest.json"]
    manifest = Jason.decode!(manifest_bytes)
    signature = entries["manifest.json.sig"]

    assert byte_size(signature) == 64
    assert Signing.verify(manifest_bytes, signature, manifest["key_id"])
    assert_describes(manifest["file"], file_name, entries[file_name])

    manifest
  end

  defp assert_describes(described, file_name, bytes) do
    assert described["name"] == file_name
    assert described["sha256"] == sha256(bytes)
    assert described["bytes"] == byte_size(bytes)
  end

  # Runs `fun` in the request's process when the export's audit event is
  # emitted: after the zip is built and before the first byte is sent.
  defp on_export_recorded(fun) do
    handler_id = "signed-export-recorded-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :audit, :org_audit_log_exported],
      fn _event, _measurements, metadata, _config -> fun.(metadata) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp build_dirs(root), do: root |> File.ls!() |> Enum.map(&Path.join(root, &1))

  defp zip_in(dir), do: Path.join(dir, "export.zip")

  # Runs `fun` once with the build's directory, in the test process, when the
  # build issues its first read of audit_events: the directory exists by then.
  # Returns the counter that says whether it ran.
  defp on_build_first_read(root, fun) do
    test_pid = self()
    handler_id = "signed-export-first-read-#{System.unique_integer([:positive])}"
    fired = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        with true <- self() == test_pid,
             %{source: "audit_events", query: "SELECT" <> _rest} <- metadata,
             [dir] <- build_dirs(root),
             0 <- :counters.get(fired, 1) do
          :counters.add(fired, 1, 1)
          fun.(dir)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fired
  end

  # Runs the :browser pipeline, then the controller with a send_file that
  # raises Bandit.TransportError with `reason`: what Bandit raises when the
  # client has closed the connection. Phoenix.ConnTest's get/2 always installs
  # the test adapter, so the controller is called directly; it re-declares
  # require_org_admin_user itself, so the org-admin gate still runs.
  defp get_closing(conn, path, reason) do
    conn
    |> bypass_through(KanbanWeb.Router, [:browser])
    |> get(path)
    |> ClosingSendFileAdapter.install(reason)
    |> OrgAuditLogExportController.call(:export)
  end

  describe "signed export" do
    @describetag :tmp_dir
    setup [:org_admin_setup, :signed_setup]

    test "no signed param and signed=false give the unsigned export", %{conn: conn} do
      for {query, type} <- [
            {"", "text/csv"},
            {"?signed=false", "text/csv"},
            {"?format=json", "application/json"},
            {"?format=json&signed=false", "application/json"},
            {"?signed[x=1&signed=false", "text/csv"}
          ] do
        answered = get(conn, "/org/audit/export" <> query)

        assert response(answered, 200)
        assert [content_type] = get_resp_header(answered, "content-type")
        assert content_type =~ type
        refute content_type =~ "zip"
      end

      assert [_, _, _, _, _] = events = export_events()
      assert Enum.all?(events, &(&1.metadata["signed"] == false))

      signed = get(conn, ~p"/org/audit/export?signed=true")
      assert [content_type] = get_resp_header(signed, "content-type")
      assert content_type =~ "application/zip"

      assert export_events() |> Enum.map(& &1.metadata["signed"]) |> Enum.sort() ==
               [false, false, false, false, false, true]
    end

    test "signed=true returns an application/zip attachment",
         %{conn: conn, org_a: org_a, org_admin: org_admin, root: root} do
      expected_file = unsigned_file(org_a, :csv, 50_000)

      conn = get(conn, ~p"/org/audit/export?signed=true")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/zip"
      assert [disposition] = get_resp_header(conn, "content-disposition")

      assert disposition =~
               ~r/\Aattachment; filename="org_audit_log_\d{4}-\d{2}-\d{2}_signed\.zip"\z/

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-export-truncated") == []

      entries = unzip(conn)

      assert entries |> Map.keys() |> Enum.sort() ==
               ~w(README.txt audit_log.csv manifest.json manifest.json.sig)

      manifest = assert_verifies(entries, "audit_log.csv")

      # Byte for byte the unsigned file for the same events, and only this
      # Organization's.
      assert entries["audit_log.csv"] == expected_file
      assert entries["audit_log.csv"] =~ ",organization_updated,"
      refute entries["audit_log.csv"] =~ "organization_created"
      refute entries["audit_log.csv"] =~ "login_failed"

      assert manifest["schema"] == "stride.audit-export.v1"
      assert manifest["instance"] == KanbanWeb.Endpoint.host()
      assert manifest["organization"] == %{"id" => org_a.id, "name" => org_a.name}
      assert manifest["generated_by"] == %{"user_id" => org_admin.id, "email" => org_admin.email}
      assert manifest["filters"] == %{"action" => nil, "from" => nil, "to" => nil}
      assert manifest["rows"] == 2
      assert manifest["truncated"] == false

      # The temporary directory is gone once the response has been sent.
      assert File.ls!(root) == []
    end

    test "the README's key URL serves the key that verifies the signature", %{conn: conn} do
      entries = conn |> get(~p"/org/audit/export?signed=true") |> unzip()
      manifest = Jason.decode!(entries["manifest.json"])

      assert [_line, key_url] =
               Regex.run(~r/^curl -fsS "([^"]+)" -o stride-audit\.pem$/m, entries["README.txt"])

      uri = URI.parse(key_url)
      assert uri.host == KanbanWeb.Endpoint.host()
      assert URI.decode_query(uri.query) == %{"format" => "pem", "kid" => manifest["key_id"]}

      pem = build_conn() |> get(uri.path <> "?" <> uri.query) |> response(200)
      {:ok, %{public_key: public_key}} = Signing.find_published(manifest["key_id"])
      assert pem == Signing.public_key_pem(public_key)

      assert :crypto.verify(
               :eddsa,
               :none,
               entries["manifest.json"],
               entries["manifest.json.sig"],
               [
                 public_key,
                 :ed25519
               ]
             )
    end

    test "format=json puts audit_log.json in the zip", %{conn: conn, org_a: org_a} do
      expected_file = unsigned_file(org_a, :json, 50_000)

      entries = conn |> get(~p"/org/audit/export?signed=true&format=json") |> unzip()

      assert entries |> Map.keys() |> Enum.sort() ==
               ~w(README.txt audit_log.json manifest.json manifest.json.sig)

      manifest = assert_verifies(entries, "audit_log.json")
      assert manifest["file"]["format"] == "json"
      assert entries["audit_log.json"] == expected_file
    end

    test "the signed export records one event with signed, key_id and sha256 matching the manifest",
         %{conn: conn, org_a: org_a, org_admin: org_admin} do
      conn =
        get(conn, ~p"/org/audit/export?signed=true&format=json&action=org_admin_appointed")

      manifest = conn |> unzip() |> assert_verifies("audit_log.json")

      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.actor_user_id == org_admin.id
      assert event.organization_id == org_a.id
      assert event.metadata["user_id"] == org_admin.id
      assert event.metadata["organization_id"] == org_a.id
      assert event.metadata["signed"] == true
      assert event.metadata["key_id"] == manifest["key_id"]
      assert event.metadata["key_id"] == Signing.current_key().key_id
      assert event.metadata["sha256"] == manifest["file"]["sha256"]
      assert event.metadata["truncated"] == manifest["truncated"]
      assert event.metadata["format"] == "json"
      assert event.metadata["filters"] == %{"action" => "org_admin_appointed"}

      assert manifest["filters"] ==
               %{"action" => "org_admin_appointed", "from" => nil, "to" => nil}
    end

    test "a signed export with an unknown action holds every event and its manifest records action null",
         %{conn: conn, org_a: org_a} do
      for {action, format, file_name} <- [
            {"bogus_action", :csv, "audit_log.csv"},
            {"organization_created", :json, "audit_log.json"}
          ] do
        expected_file = unsigned_file(org_a, format, 50_000)

        entries =
          conn
          |> get(
            ~p"/org/audit/export?#{%{"signed" => "true", "format" => Atom.to_string(format), "action" => action}}"
          )
          |> unzip()

        manifest = assert_verifies(entries, file_name)

        # The same file as no action param: every event of this Organization.
        assert entries[file_name] == expected_file
        assert manifest["filters"] == %{"action" => nil, "from" => nil, "to" => nil}
      end

      assert export_events() |> Enum.map(& &1.metadata["filters"]) == [%{}, %{}]
    end

    test "the event is emitted while the zip is still on disk, before anything is sent",
         %{conn: conn, root: root} do
      test_pid = self()

      on_export_recorded(fn _metadata ->
        zips = root |> build_dirs() |> Enum.map(&zip_in/1)
        send(test_pid, {:recorded, Enum.map(zips, &File.regular?/1)})
      end)

      conn = get(conn, ~p"/org/audit/export?signed=true")

      assert_received {:recorded, [true]}
      assert response(conn, 200)
      assert File.ls!(root) == []
    end

    test "a signed file never holds its own event; the next one holds the first one's",
         %{conn: conn} do
      first = conn |> get(~p"/org/audit/export?signed=true&format=json") |> unzip()

      assert first["audit_log.json"] |> Jason.decode!() |> Enum.map(& &1["action"]) ==
               ["org_admin_appointed", "organization_updated"]

      second = conn |> get(~p"/org/audit/export?signed=true&format=json") |> unzip()

      assert [%{"action" => "org_audit_log_exported", "metadata" => metadata} | _] =
               Jason.decode!(second["audit_log.json"])

      assert metadata["sha256"] == sha256(first["audit_log.json"])
      assert metadata["signed"] == true
    end

    test "organization_id and actor_email params cannot widen or probe a signed export",
         %{conn: conn, org_a: org_a, org_b: org_b} do
      site_admin = admin_fixture()

      Repo.insert!(%AuditEvent{
        action: "organization_updated",
        organization_id: org_a.id,
        actor_user_id: site_admin.id,
        ip: "203.0.113.9",
        inserted_at: ~U[2026-10-05 00:00:00.000000Z],
        metadata: %{"user_id" => site_admin.id, "ip" => "203.0.113.9"}
      })

      params = %{
        "signed" => "true",
        "format" => "json",
        "organization_id" => org_b.id,
        "actor_email" => site_admin.email
      }

      entries = conn |> get(~p"/org/audit/export?#{params}") |> unzip()
      manifest = assert_verifies(entries, "audit_log.json")

      assert entries["audit_log.json"] |> Jason.decode!() |> Enum.map(& &1["action"]) ==
               ["organization_updated", "org_admin_appointed", "organization_updated"]

      # The site admin's row is there, without their email, IP or id.
      for {_name, bytes} <- entries do
        refute bytes =~ site_admin.email
        refute bytes =~ "203.0.113.9"
      end

      assert manifest["organization"]["id"] == org_a.id
      assert manifest["filters"] == %{"action" => nil, "from" => nil, "to" => nil}
      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.metadata["filters"] == %{}
    end

    test "an org-admin of another Organization gets only their own events", %{org_b: org_b} do
      other_admin = user_fixture()
      organization_member_fixture(org_b, other_admin, :org_admin)

      entries =
        build_conn()
        |> log_in_user(other_admin)
        |> get(~p"/org/audit/export?signed=true&format=json")
        |> unzip()

      manifest = assert_verifies(entries, "audit_log.json")

      assert entries["audit_log.json"] |> Jason.decode!() |> Enum.map(& &1["action"]) ==
               ["organization_created"]

      assert manifest["organization"]["id"] == org_b.id
      assert manifest["generated_by"]["email"] == other_admin.email
    end

    test "a non-org-admin is refused and nothing is built or recorded", %{root: root} do
      member = user_fixture()
      organization_member_fixture(organization_fixture(), member, :member)

      for user <- [member, user_fixture(), admin_fixture()] do
        conn = build_conn() |> log_in_user(user) |> get(~p"/org/audit/export?signed=true")

        assert redirected_to(conn) == ~p"/boards"
      end

      assert build_conn() |> get(~p"/org/audit/export?signed=true") |> redirected_to() ==
               ~p"/users/log-in"

      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == []
    end

    test "signed with an unsupported format is refused as any other", %{conn: conn, root: root} do
      conn = get(conn, ~p"/org/audit/export?signed=true&format=pdf")

      assert redirected_to(conn) == ~p"/org/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Unsupported export format."
      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == []
    end

    test "audit telemetry carries signed, key_id and sha256 but no filters or ip, and the export span has format zip",
         %{conn: conn} do
      attach_telemetry([
        [:kanban, :audit, :org_audit_log_exported],
        [:kanban, :export, :start],
        [:kanban, :export, :stop]
      ])

      conn = get(conn, ~p"/org/audit/export?signed=true&format=json&action=org_admin_appointed")
      manifest = conn |> unzip() |> assert_verifies("audit_log.json")

      assert_receive {:telemetry_event, [:kanban, :audit, :org_audit_log_exported], _, metadata}
      assert metadata.signed == true
      assert metadata.key_id == manifest["key_id"]
      assert metadata.sha256 == manifest["file"]["sha256"]
      assert metadata.truncated == false
      assert metadata.format == "json"
      refute Map.has_key?(metadata, :filters)
      refute Map.has_key?(metadata, :ip)

      assert_receive {:telemetry_event, [:kanban, :export, :start], _, start}
      assert_receive {:telemetry_event, [:kanban, :export, :stop], %{duration: _}, stop}

      for metadata <- [start, stop] do
        assert Map.delete(metadata, :telemetry_span_context) == %{
                 kind: :org_audit_log,
                 format: :zip
               }
      end

      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
    end

    test "two signed exports at once each get their own temp dir and both verify",
         %{org_a: org_a, org_admin: org_admin, root: root} do
      test_pid = self()

      # Holds each request after its zip is built and its event recorded, so
      # both temporary directories exist at the same moment.
      on_export_recorded(fn _metadata ->
        send(test_pid, {:built, self()})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end)

      formats = ["csv", "json"]

      tasks =
        for format <- formats do
          conn = log_in_user(build_conn(), org_admin)
          Task.async(fn -> get(conn, ~p"/org/audit/export?signed=true&format=#{format}") end)
        end

      assert_receive {:built, first}, 10_000
      assert_receive {:built, second}, 10_000

      assert [dir_a, dir_b] = build_dirs(root)
      assert dir_a != dir_b
      assert dir_a |> zip_in() |> File.regular?()
      assert dir_b |> zip_in() |> File.regular?()

      for pid <- [first, second], do: send(pid, :release)
      conns = Task.await_many(tasks, 30_000)

      manifests =
        for {conn, format} <- Enum.zip(conns, formats) do
          conn |> unzip() |> assert_verifies("audit_log.#{format}")
        end

      assert Enum.all?(manifests, &(&1["organization"]["id"] == org_a.id))

      assert [_, _] = events = AuditLog.list_events(action: :org_audit_log_exported)

      assert events |> Enum.map(& &1.metadata["sha256"]) |> Enum.sort() ==
               manifests |> Enum.map(& &1["file"]["sha256"]) |> Enum.sort()

      assert File.ls!(root) == []
    end

    test "signing off refuses with the flash and records nothing", %{conn: conn, root: root} do
      attach_telemetry([[:kanban, :export, :start]])
      Application.put_env(:kanban, Signing, [])

      conn = get(conn, ~p"/org/audit/export?signed=true")

      assert redirected_to(conn) == ~p"/org/audit"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Signed exports are not set up on this server."

      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == []
      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}
    end

    test "a build failure redirects with a flash, records no event and leaves no temp dir",
         %{conn: conn, root: root} do
      attach_telemetry([[:kanban, :export, :stop]])

      # A regular file where the temporary root should be: nothing can be
      # created under it.
      blocked = Path.join(root, "not-a-directory")
      File.write!(blocked, "")
      Application.put_env(:kanban, SignedExport, tmp_root: blocked)

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn -> get(conn, ~p"/org/audit/export?signed=true") end)

      assert redirected_to(conn) == ~p"/org/audit"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The signed export could not be built. Try again."

      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ root
      refute log =~ root
      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == ["not-a-directory"]

      # A failed build still ends the export span.
      assert_receive {:telemetry_event, [:kanban, :export, :stop], _,
                      %{kind: :org_audit_log, format: :zip}}
    end

    test "a build that fails part-way leaves no temp dir and records nothing",
         %{conn: conn, root: root} do
      # A directory planted where manifest.json goes makes that write fail.
      fired =
        on_build_first_read(root, fn dir ->
          dir |> Path.join("manifest.json") |> File.mkdir!()
        end)

      {conn, _log} =
        ExUnit.CaptureLog.with_log(fn -> get(conn, ~p"/org/audit/export?signed=true") end)

      assert :counters.get(fired, 1) == 1
      assert redirected_to(conn) == ~p"/org/audit"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The signed export could not be built. Try again."

      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == []
    end

    test "a key removed during the build refuses with the signing-off flash and records nothing",
         %{conn: conn, root: root} do
      fired = on_build_first_read(root, fn _dir -> Application.put_env(:kanban, Signing, []) end)

      conn = get(conn, ~p"/org/audit/export?signed=true")

      assert :counters.get(fired, 1) == 1
      assert redirected_to(conn) == ~p"/org/audit"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Signed exports are not set up on this server."

      assert AuditLog.list_events(action: :org_audit_log_exported) == []
      assert File.ls!(root) == []
    end

    test "an org-admin removed during the build gets no file and is refused as by the gate",
         %{conn: conn, org_a: org_a, org_admin: org_admin, root: root} do
      organization_member_fixture(org_a, user_fixture(), :org_admin)
      site_admin = admin_fixture()

      fired =
        on_build_first_read(root, fn _dir ->
          {:ok, _membership} = Organizations.remove_org_admin(site_admin, org_a, org_admin)
        end)

      conn = get(conn, ~p"/org/audit/export?signed=true")

      assert :counters.get(fired, 1) == 1
      assert conn.halted
      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
      assert get_resp_header(conn, "content-disposition") == []

      assert AuditLog.list_events(action: :org_audit_log_exported) == []

      assert [event] =
               AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)

      assert event.metadata["gate"] == "require_org_admin"
      assert File.ls!(root) == []
    end

    test "a send that fails still removes the temp dir, and the event stays recorded",
         %{conn: conn, root: root} do
      # The zip disappears between the audit row and the send, as a stand-in
      # for a download that dies: sending it raises.
      on_export_recorded(fn _metadata ->
        [dir] = build_dirs(root)
        dir |> zip_in() |> File.rm!()
      end)

      assert_raise File.Error, fn -> get(conn, ~p"/org/audit/export?signed=true") end

      assert File.ls!(root) == []
      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.metadata["signed"] == true
    end

    test "a connection closed during the signed send ends normally, removes the temp dir and keeps the event",
         %{conn: conn, root: root} do
      test_pid = self()
      on_export_recorded(fn _metadata -> send(test_pid, {:dirs_at_send, build_dirs(root)}) end)

      conn = get_closing(conn, "/org/audit/export?signed=true", :closed)

      assert_received {:dirs_at_send, [_dir]}

      # :sent, not :unset: Bandit raises Plug.Conn.NotSentError for an :unset
      # conn, and :sent makes it end the request without writing again.
      assert conn.state == :sent
      assert File.ls!(root) == []
      assert [event] = AuditLog.list_events(action: :org_audit_log_exported)
      assert event.metadata["signed"] == true
    end

    test "a closed connection logs one info line with no path or email",
         %{conn: conn, root: root, org_admin: org_admin} do
      # config/test.exs logs at :warning; this file is async: false.
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      occurrences = Repo.aggregate(ErrorTracker.Occurrence, :count)

      for reason <- [:closed, :enotconn, :einval, :econnaborted, :econnreset] do
        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            get_closing(conn, "/org/audit/export?signed=true", reason)
          end)

        assert [line] =
                 log |> String.split("\n") |> Enum.filter(&(&1 =~ "signed audit export"))

        assert line =~ "[info] signed audit export download ended: client closed"
        assert line =~ inspect(reason)
        refute log =~ root
        refute log =~ org_admin.email
        refute log =~ "127.0.0.1"
      end

      # Info, not warning: nothing is captured at warning level.
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          get_closing(conn, "/org/audit/export?signed=true", :closed)
        end)

      refute log =~ "signed audit export"
      assert File.ls!(root) == []
      assert length(AuditLog.list_events(action: :org_audit_log_exported)) == 6
      # A client closing is not an error: ErrorTracker records nothing.
      assert Repo.aggregate(ErrorTracker.Occurrence, :count) == occurrences
    end

    test "another transport reason logs a warning",
         %{conn: conn, root: root, org_admin: org_admin} do
      # :enoent is a failure on the server's side of the sendfile, which Bandit
      # raises as the same error; :timeout is a transport failure of its own.
      for reason <- [:enoent, :timeout] do
        occurrences = Repo.aggregate(ErrorTracker.Occurrence, :count)

        {sent, log} =
          ExUnit.CaptureLog.with_log(fn ->
            get_closing(conn, "/org/audit/export?signed=true", reason)
          end)

        assert sent.state == :sent

        assert [line] =
                 log |> String.split("\n") |> Enum.filter(&(&1 =~ "signed audit export"))

        assert line =~
                 "[warning] signed audit export download failed: transport error (#{inspect(reason)})"

        refute log =~ root
        refute log =~ org_admin.email
        refute log =~ "127.0.0.1"
        assert File.ls!(root) == []

        # Still reported: this is not a client going away.
        assert Repo.aggregate(ErrorTracker.Occurrence, :count) == occurrences + 1
      end

      assert length(AuditLog.list_events(action: :org_audit_log_exported)) == 2
    end

    test "the export span stops without an exception event when the client closes",
         %{conn: conn} do
      attach_telemetry([
        [:kanban, :export, :start],
        [:kanban, :export, :stop],
        [:kanban, :export, :exception]
      ])

      get_closing(conn, "/org/audit/export?signed=true", :closed)

      assert_receive {:telemetry_event, [:kanban, :export, :start], _, _}
      assert_receive {:telemetry_event, [:kanban, :export, :stop], %{duration: _}, stop}
      assert Map.delete(stop, :telemetry_span_context) == %{kind: :org_audit_log, format: :zip}
      refute_received {:telemetry_event, [:kanban, :export, :exception], _, _}
    end

    for {locale, signing_off, build_failed} <- [
          {"ja", "このサーバーでは署名付きエクスポートが設定されていません。", "署名付きエクスポートを作成できませんでした。もう一度お試しください。"},
          {"zh", "此服务器未设置签名导出。", "无法生成签名导出，请重试。"}
        ] do
      test "the refusal flashes are translated under #{locale}", %{conn: conn, root: root} do
        conn = Plug.Test.init_test_session(conn, %{"locale" => unquote(locale)})

        blocked = Path.join(root, "not-a-directory")
        File.write!(blocked, "")
        Application.put_env(:kanban, SignedExport, tmp_root: blocked)

        {failed, _log} =
          ExUnit.CaptureLog.with_log(fn -> get(conn, ~p"/org/audit/export?signed=true") end)

        assert Phoenix.Flash.get(failed.assigns.flash, :error) == unquote(build_failed)

        Application.put_env(:kanban, Signing, [])
        refused = get(conn, ~p"/org/audit/export?signed=true")

        assert Phoenix.Flash.get(refused.assigns.flash, :error) == unquote(signing_off)
      end
    end
  end

  describe "signed export limits" do
    @describetag :tmp_dir
    setup [:limits_setup, :signed_setup]

    test "truncated comes from the stream: false at exactly the cap, true past it, with no header",
         %{conn: conn, organization: organization} do
      insert_cap_events!(organization, @max_rows)
      path = ~p"/org/audit/export?signed=true&format=json&action=organization_updated"

      # Exactly the cap. The signed file holds no audit row of its own, so
      # nothing else takes a place.
      at_cap = get(conn, path)

      assert get_resp_header(at_cap, "x-export-truncated") == []
      manifest = at_cap |> unzip() |> assert_verifies("audit_log.json")

      assert manifest["truncated"] == false
      assert manifest["rows"] == @max_rows
      assert [%{metadata: %{"truncated" => false}}] = export_events()

      # One more row than the cap.
      insert_cap_events!(organization, 1)
      cut = get(conn, path)

      assert get_resp_header(cut, "x-export-truncated") == []
      entries = unzip(cut)
      manifest = assert_verifies(entries, "audit_log.json")

      assert manifest["truncated"] == true
      assert manifest["rows"] == @max_rows
      assert entries["audit_log.json"] |> Jason.decode!() |> length() == @max_rows

      assert export_events() |> Enum.map(& &1.metadata["truncated"]) |> Enum.sort() ==
               [false, true]
    end

    test "signed and unsigned exports share the limit", %{conn: conn} do
      attach_telemetry([[:kanban, :rate_limit, :denied]])

      assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      assert conn |> get(~p"/org/audit/export?format=json") |> response(200)
      assert length(export_events()) == @rate_limit

      for query <- ["?signed=true", "?signed=true&format=json", ""] do
        refused = get(conn, "/org/audit/export" <> query)

        assert redirected_to(refused) == ~p"/org/audit"

        assert Phoenix.Flash.get(refused.assigns.flash, :error) ==
                 "Too many exports. Try again later."

        assert_receive {:telemetry_event, [:kanban, :rate_limit, :denied], _,
                        %{surface: :org_audit_export}}
      end

      assert length(export_events()) == @rate_limit
    end

    test "signing off refuses with the flash, records nothing and is not charged",
         %{conn: conn} do
      attach_telemetry([[:kanban, :rate_limit, :denied]])
      {:ok, signing} = Application.fetch_env(:kanban, Signing)
      Application.put_env(:kanban, Signing, [])

      for _ <- 1..5 do
        refused = get(conn, ~p"/org/audit/export?signed=true")

        assert redirected_to(refused) == ~p"/org/audit"

        assert Phoenix.Flash.get(refused.assigns.flash, :error) ==
                 "Signed exports are not set up on this server."
      end

      assert export_events() == []
      refute_received {:telemetry_event, [:kanban, :rate_limit, :denied], _, _}

      # The whole allowance is still there once signing is back.
      Application.put_env(:kanban, Signing, signing)

      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      end

      assert length(export_events()) == @rate_limit
    end

    test "an unsupported format on a signed request is not charged", %{conn: conn} do
      for _ <- 1..5 do
        refused = get(conn, ~p"/org/audit/export?signed=true&format=pdf")
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Unsupported export format."
      end

      assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      assert length(export_events()) == 1
    end

    test "a signed value other than true or false is refused with the flash, records nothing and is not charged",
         %{conn: conn} do
      attach_telemetry([[:kanban, :rate_limit, :denied]])

      for query <- @invalid_signed_queries do
        refused = get(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed
      end

      assert export_events() == []
      refute_received {:telemetry_event, [:kanban, :rate_limit, :denied], _, _}

      # The whole allowance is still there.
      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      end

      assert length(export_events()) == @rate_limit
    end

    test "a repeated signed param is refused and is not charged", %{conn: conn} do
      for query <- [
            "signed=true&signed=false",
            "signed=yes&signed=true",
            "signed=true&signed=true",
            "signed=false&signed=false",
            "sign%65d=true&signed=false",
            "signed[]=true&signed=false",
            "signed[a]=true&signed=false"
          ] do
        refused = get(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed
      end

      assert export_events() == []

      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      end
    end

    test "a list-valued signed param is refused", %{conn: conn} do
      for query <- ["signed[]=true", "signed[]=true&signed[]=false", "signed[a]=true"] do
        refused = get(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed
      end

      assert export_events() == []
    end

    test "an invalid signed value is refused while signing is off", %{conn: conn} do
      Application.put_env(:kanban, Signing, [])

      for query <- ["signed=yes", "signed=TRUE", "signed[]=true"] do
        refused = get(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed
      end

      assert export_events() == []
    end

    test "an unsupported format with an invalid signed value gets the format flash",
         %{conn: conn} do
      for query <- ["signed=yes&format=pdf", "format=pdf&signed[]=true"] do
        refused = get(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Unsupported export format."
      end

      assert export_events() == []
    end

    test "the invalid-signed refusal flash is translated under ja and zh", %{conn: conn} do
      for {locale, message} <- [
            {"ja", "signed パラメーターは true または false でなければなりません。"},
            {"zh", "signed 参数必须为 true 或 false。"}
          ] do
        refused =
          conn
          |> Plug.Test.init_test_session(%{"locale" => locale})
          |> get(~p"/org/audit/export?signed=yes")

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == message
      end
    end

    test "the invalid-signed refusal flash is translated in the other locales", %{conn: conn} do
      for {locale, message} <- [
            {"de", "Der Parameter signed muss true oder false sein."},
            {"en", @invalid_signed},
            {"es", "El parámetro signed debe ser true o false."},
            {"fr", "Le paramètre signed doit valoir true ou false."},
            {"pt", "O parâmetro signed deve ser true ou false."}
          ] do
        refused =
          conn
          |> Plug.Test.init_test_session(%{"locale" => locale})
          |> get(~p"/org/audit/export?signed=yes")

        assert Phoenix.Flash.get(refused.assigns.flash, :error) == message
        refute message =~ "yes"
      end
    end
  end

  describe "the signed rule" do
    defp squish(text), do: text |> String.split() |> Enum.join(" ")

    test "the two docs and the moduledoc state that signed takes only true or false" do
      for path <- ["docs/audit-log-signed-exports.md", "docs/organizations.md"] do
        text = path |> File.read!() |> squish()

        assert text =~ "parameter takes exactly `true` or `false`", path
        assert text =~ "given more than once", path
      end

      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(KanbanWeb.OrgAuditLogExportController)

      moduledoc = squish(moduledoc)
      assert moduledoc =~ "The `signed` param takes exactly two values."
      assert moduledoc =~ "given more than once in the query string"
    end
  end

  describe "HEAD" do
    @describetag :tmp_dir
    setup [:limits_setup, :signed_setup]

    test "a signed HEAD sends the zip headers and builds, charges and records nothing",
         %{conn: conn, root: root} do
      attach_telemetry([:kanban, :export, :start])

      for _ <- 1..(@rate_limit + 1) do
        answered = head(conn, ~p"/org/audit/export?signed=true")

        assert response(answered, 200) == ""
        assert [content_type] = get_resp_header(answered, "content-type")
        assert content_type =~ "application/zip"

        assert [disposition] = get_resp_header(answered, "content-disposition")

        assert disposition =~
                 ~r/\Aattachment; filename="org_audit_log_\d{4}-\d{2}-\d{2}_signed\.zip"\z/

        assert get_resp_header(answered, "cache-control") == ["no-store"]
      end

      assert export_events() == []
      assert File.ls!(root) == []
      refute_received {:telemetry_event, [:kanban, :export, :start], _, _}

      # The whole allowance is still there for a GET.
      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export?signed=true") |> response(200)
      end

      assert length(export_events()) == @rate_limit
    end

    test "an unsigned HEAD sends the file headers and charges and records nothing", %{conn: conn} do
      for {path, type, name} <- [
            {~p"/org/audit/export", "text/csv", "csv"},
            {~p"/org/audit/export?format=json&signed=false", "application/json", "json"}
          ] do
        answered = head(conn, path)

        assert response(answered, 200) == ""
        assert [content_type] = get_resp_header(answered, "content-type")
        assert content_type =~ type

        assert [disposition] = get_resp_header(answered, "content-disposition")

        assert disposition =~
                 ~r/\Aattachment; filename="org_audit_log_\d{4}-\d{2}-\d{2}\.#{name}"\z/

        assert get_resp_header(answered, "cache-control") == ["no-store"]
        assert get_resp_header(answered, "x-export-truncated") == []
      end

      assert export_events() == []

      for _ <- 1..@rate_limit do
        assert conn |> get(~p"/org/audit/export") |> response(200)
      end
    end

    test "a HEAD with an unknown action still records nothing", %{conn: conn, root: root} do
      for path <- [
            ~p"/org/audit/export?action=bogus_action",
            ~p"/org/audit/export?format=json&action=bogus_action",
            ~p"/org/audit/export?signed=true&action=bogus_action"
          ] do
        assert conn |> head(path) |> response(200) == ""
      end

      assert export_events() == []
      assert File.ls!(root) == []
    end

    test "a HEAD is refused as a GET is for an unsupported format and for signing off",
         %{conn: conn} do
      refused = head(conn, ~p"/org/audit/export?signed=true&format=pdf")
      assert redirected_to(refused) == ~p"/org/audit"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Unsupported export format."

      Application.put_env(:kanban, Signing, [])

      refused = head(conn, ~p"/org/audit/export?signed=true")
      assert redirected_to(refused) == ~p"/org/audit"

      assert Phoenix.Flash.get(refused.assigns.flash, :error) ==
               "Signed exports are not set up on this server."

      assert export_events() == []
    end

    test "a HEAD with an invalid signed value is refused as a GET is", %{conn: conn, root: root} do
      for query <- [
            "signed=yes",
            "signed=1&format=json",
            "signed[]=true",
            "signed=true&signed=false",
            "signed[]=true&signed=false"
          ] do
        refused = head(conn, "/org/audit/export?" <> query)

        assert redirected_to(refused) == ~p"/org/audit"
        assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed
      end

      Application.put_env(:kanban, Signing, [])

      refused = head(conn, ~p"/org/audit/export?signed=TRUE")
      assert redirected_to(refused) == ~p"/org/audit"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) == @invalid_signed

      assert export_events() == []
      assert File.ls!(root) == []
    end
  end
end
