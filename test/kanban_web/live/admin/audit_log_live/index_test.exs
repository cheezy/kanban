defmodule KanbanWeb.Admin.AuditLogLive.IndexTest do
  # async: false — the access-control tests assert on audit_events rows written
  # by the auth gate, and the table is shared.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), user: admin}
  end

  defp insert_event!(action, inserted_at, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Repo.insert!(%AuditEvent{
      action: action,
      inserted_at: inserted_at,
      actor_user_id: actor && actor.id,
      ip: Keyword.get(opts, :ip),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  describe "access control" do
    setup :register_and_log_in_user

    test "non-admin is redirected to / and a permission_denied event is recorded",
         %{conn: conn, user: user} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/admin/audit-log")
      assert flash["error"] =~ "admin"

      assert [%AuditEvent{actor_user_id: actor_id}] =
               AuditLog.list_events(action: :permission_denied)

      assert actor_id == user.id
    end

    test "unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/audit-log")
    end
  end

  describe "admin viewer" do
    setup [:register_and_log_in_admin]

    setup %{user: admin} do
      base = ~U[2026-10-01 09:00:00.000000Z]

      old =
        insert_event!("login_failed", base,
          ip: "198.51.100.7",
          metadata: %{"email" => "victim@example.com"}
        )

      new =
        insert_event!("api_token_created", DateTime.add(base, 86_400),
          actor: admin,
          metadata: %{"user_id" => admin.id, "board_id" => 3}
        )

      %{old: old, new: new}
    end

    test "renders events newest first with actor, IP and metadata",
         %{conn: conn, old: old, new: new, user: admin} do
      {:ok, view, html} = live(conn, ~p"/admin/audit-log")

      assert html =~ "Audit Log"
      assert has_element?(view, "#events-#{new.id}", admin.email)
      assert has_element?(view, "#events-#{old.id}", "198.51.100.7")
      assert has_element?(view, "#events-#{old.id}", "victim@example.com")
      assert has_element?(view, "#events-#{old.id}", "2026-10-01 09:00:00")

      {new_pos, _} = :binary.match(html, "events-#{new.id}")
      {old_pos, _} = :binary.match(html, "events-#{old.id}")
      assert new_pos < old_pos
    end

    test "the action filter patches the URL and shows only matching rows",
         %{conn: conn, old: old, new: new} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log")

      view
      |> form("#audit-log-filters", filters: %{action: "login_failed"})
      |> render_change()

      assert_patch(view, ~p"/admin/audit-log?#{%{"action" => "login_failed"}}")
      assert has_element?(view, "#events-#{old.id}")
      refute has_element?(view, "#events-#{new.id}")
    end

    test "filters by actor email (account or recorded email)",
         %{conn: conn, old: old, new: new, user: admin} do
      {:ok, view, _html} =
        live(conn, ~p"/admin/audit-log?#{%{"actor_email" => String.upcase(admin.email)}}")

      assert has_element?(view, "#events-#{new.id}")
      refute has_element?(view, "#events-#{old.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?actor_email=victim@example.com")
      assert has_element?(view, "#events-#{old.id}")
      refute has_element?(view, "#events-#{new.id}")
    end

    test "filters by date range, and an invalid date is ignored",
         %{conn: conn, old: old, new: new} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?from=2026-10-02&to=2026-10-02")
      assert has_element?(view, "#events-#{new.id}")
      refute has_element?(view, "#events-#{old.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?from=not-a-date&to=2026-13-40")
      assert has_element?(view, "#events-#{new.id}")
      assert has_element?(view, "#events-#{old.id}")
    end

    test "an out-of-range year is ignored instead of crashing the page",
         %{conn: conn, old: old, new: new} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?from=-4713-01-01&to=-5000-01-01")

      assert has_element?(view, "#events-#{new.id}")
      assert has_element?(view, "#events-#{old.id}")
    end

    test "a tampered cursor with an out-of-range year shows the first page instead of crashing",
         %{conn: conn, old: old, new: new} do
      cursor = Base.url_encode64("-200000000000000000:1", padding: false)

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?#{%{"cursor" => cursor}}")

      assert has_element?(view, "#events-#{new.id}")
      assert has_element?(view, "#events-#{old.id}")
      refute has_element?(view, "#audit-log-newest")
    end

    test "shows an empty state when nothing matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?action=nothing_matches")

      assert has_element?(view, "#audit-log-empty")
      refute has_element?(view, "#audit-events")
    end

    test "an unknown action in the URL never becomes an atom and simply matches nothing",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?action=Robert');DROP")

      # Rejected by the strict parser, so the filter is not applied at all.
      refute has_element?(view, "#audit-log-empty")
      refute has_element?(view, "#audit-log-clear-filters")
    end

    test "paginates by keyset with older/newest links", %{conn: conn, old: old} do
      base = ~U[2026-10-05 00:00:00.000000Z]
      for i <- 1..50, do: insert_event!("permission_denied", DateTime.add(base, i))

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log")

      refute has_element?(view, "#events-#{old.id}")
      refute has_element?(view, "#audit-log-newest")

      view |> element("#audit-log-next-page") |> render_click()

      assert "/admin/audit-log?cursor=" <> _cursor = assert_patch(view)
      assert has_element?(view, "#events-#{old.id}")
      assert has_element?(view, "#audit-log-newest")
      refute has_element?(view, "#audit-log-next-page")
    end

    test "export links carry the current filters but never the cursor", %{conn: conn} do
      base = ~U[2026-10-05 00:00:00.000000Z]
      for i <- 1..51, do: insert_event!("login_failed", DateTime.add(base, i))

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log?action=login_failed")
      view |> element("#audit-log-next-page") |> render_click()

      csv_href = view |> element("#audit-log-export-csv") |> render() |> href()
      json_href = view |> element("#audit-log-export-json") |> render() |> href()

      assert csv_href =~ "/admin/audit-log/export?"
      assert csv_href =~ "action=login_failed"
      assert csv_href =~ "format=csv"
      assert json_href =~ "format=json"
      refute csv_href =~ "cursor"
    end

    test "an event with no actor reads as no person in German", %{conn: conn, old: old} do
      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "de"})
        |> live(~p"/admin/audit-log")

      assert has_element?(view, "#events-#{old.id}", "Niemand")
      refute has_element?(view, "#events-#{old.id}", "Keine")
    end

    test "the Newest page button says go to the newest in Japanese",
         %{conn: conn, new: new} do
      cursor = Kanban.AuditLog.Query.encode_cursor(new)

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "ja"})
        |> live(~p"/admin/audit-log?#{%{"cursor" => cursor}}")

      assert has_element?(view, "#audit-log-newest", "最新")
      refute has_element?(view, "#audit-log-newest", "新着順")
    end

    test "labels a deleted actor by the id kept in the metadata", %{conn: conn} do
      gone = user_fixture()

      event =
        insert_event!("api_token_revoked", ~U[2026-10-06 00:00:00.000000Z],
          actor: gone,
          metadata: %{"user_id" => gone.id}
        )

      Repo.delete!(gone)

      {:ok, view, _html} = live(conn, ~p"/admin/audit-log")
      assert has_element?(view, "#events-#{event.id}", "User ##{gone.id} (deleted)")
    end

    test "escapes HTML in stored metadata", %{conn: conn} do
      insert_event!("login_failed", ~U[2026-10-06 00:00:00.000000Z],
        metadata: %{"email" => "<script>alert(1)</script>"}
      )

      {:ok, _view, html} = live(conn, ~p"/admin/audit-log")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "the action filter offers every stored action", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/audit-log")

      assert has_element?(view, ~s(#audit-log-filters option[value="login_failed"]))
      assert has_element?(view, ~s(#audit-log-filters option[value="api_token_created"]))
    end
  end

  defp href(html) do
    [_, href] = Regex.run(~r/href="([^"]+)"/, html)
    String.replace(href, "&amp;", "&")
  end
end
