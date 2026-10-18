defmodule KanbanWeb.OrgLive.AuditLogTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  @refusal "You must be an org-admin of an Organization to access this page."

  defp insert_event!(action, organization, inserted_at, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Repo.insert!(%AuditEvent{
      action: action,
      organization_id: organization && organization.id,
      actor_user_id: actor && actor.id,
      inserted_at: inserted_at,
      ip: Keyword.get(opts, :ip),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  defp org_admin_setup(%{conn: conn}) do
    org_a = organization_fixture(%{name: "Acme Widgets"})
    org_b = organization_fixture(%{name: "Other Org"})
    org_admin = user_fixture()
    organization_member_fixture(org_a, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org_a: org_a, org_b: org_b, org_admin: org_admin}
  end

  describe "access control" do
    test "a member is redirected to /boards and the refusal is audited", %{conn: conn} do
      member = user_fixture()
      organization_member_fixture(organization_fixture(), member, :member)

      assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
               live(log_in_user(conn, member), ~p"/org/audit")

      assert flash["error"] == @refusal

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
      assert event.metadata["gate"] == "require_org_admin"
    end

    test "a free user in no Organization is redirected to /boards", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/boards"}}} =
               live(log_in_user(conn, user_fixture()), ~p"/org/audit")
    end

    test "a site admin is redirected to /boards", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
               live(log_in_user(conn, admin_fixture()), ~p"/org/audit")

      assert flash["error"] == @refusal
    end

    test "an unauthenticated visitor is sent to log in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/org/audit")
    end
  end

  describe "an org-admin removed while the audit log is open" do
    setup :org_admin_setup

    setup %{org_a: org_a, conn: conn, org_admin: org_admin} do
      insert_event!("org_admin_appointed", org_a, ~U[2026-10-01 12:00:00.000000Z])
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      Kanban.Organizations.OrganizationMember
      |> Repo.get_by!(user_id: org_admin.id)
      |> Repo.delete!()

      %{view: view}
    end

    test "is refused when paging and the refusal is audited", %{view: view, org_admin: org_admin} do
      assert {:error, {:redirect, %{to: "/boards"}}} =
               render_patch(view, ~p"/org/audit?cursor=anything")

      assert {"/boards", %{"error" => @refusal}} = assert_redirect(view)

      assert [event] =
               AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)

      assert event.metadata["gate"] == "require_org_admin"
    end

    test "is refused when filtering", %{view: view} do
      view
      |> form("#audit-log-filters", filters: %{action: "org_admin_appointed"})
      |> render_change()

      assert_redirect(view, ~p"/boards")
    end
  end

  describe "an org-admin demoted to member while the audit log is open" do
    setup :org_admin_setup

    test "is refused on the next patch", %{conn: conn, org_admin: org_admin} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      Kanban.Organizations.OrganizationMember
      |> Repo.get_by!(user_id: org_admin.id)
      |> Ecto.Changeset.change(role: :member)
      |> Repo.update!()

      assert {:error, {:redirect, %{to: "/boards"}}} = render_patch(view, ~p"/org/audit?action=x")
    end
  end

  describe "an org-admin who stays an org-admin" do
    setup :org_admin_setup

    test "keeps paging and filtering without being refused", %{conn: conn, org_admin: org_admin} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert render_patch(view, ~p"/org/audit?action=org_admin_appointed") =~
               "Organization audit log"

      assert AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id) == []
    end
  end

  describe "the Organization audit log" do
    setup :org_admin_setup

    setup %{org_a: org_a, org_b: org_b, org_admin: org_admin} do
      base = ~U[2026-10-01 09:00:00.000000Z]

      updated =
        insert_event!("organization_updated", org_a, base,
          actor: org_admin,
          ip: "198.51.100.7",
          metadata: %{"organization_id" => org_a.id}
        )

      appointed =
        insert_event!("org_admin_appointed", org_a, DateTime.add(base, 86_400),
          metadata: %{"member_user_id" => 42}
        )

      other = insert_event!("organization_created", org_b, DateTime.add(base, 172_800))
      unscoped = insert_event!("login_failed", nil, DateTime.add(base, 259_200))

      %{updated: updated, appointed: appointed, other: other, unscoped: unscoped}
    end

    test "shows only the Organization's events, newest first", %{
      conn: conn,
      updated: updated,
      appointed: appointed,
      other: other,
      unscoped: unscoped
    } do
      {:ok, view, html} = live(conn, ~p"/org/audit")

      assert html =~ "Organization audit log"
      assert html =~ "Acme Widgets"
      assert has_element?(view, "#events-#{updated.id}")
      assert has_element?(view, "#events-#{appointed.id}")
      refute has_element?(view, "#events-#{other.id}")
      refute has_element?(view, "#events-#{unscoped.id}")
      assert html =~ "198.51.100.7"

      [first, second] =
        Regex.scan(~r/id="events-(\d+)"/, render(view), capture: :all_but_first)

      assert [first, second] == [["#{appointed.id}"], ["#{updated.id}"]]
    end

    test "an organization_id in the URL changes nothing", %{
      conn: conn,
      org_b: org_b,
      other: other,
      updated: updated
    } do
      {:ok, view, _html} = live(conn, ~p"/org/audit?organization_id=#{org_b.id}")

      refute has_element?(view, "#events-#{other.id}")
      assert has_element?(view, "#events-#{updated.id}")
    end

    test "the action filter lists only the Organization's actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      options =
        view
        |> element("#audit-log-filters select")
        |> render()

      assert options =~ "organization_updated"
      assert options =~ "org_admin_appointed"
      refute options =~ "organization_created"
      refute options =~ "login_failed"
    end

    test "filtering by action patches the URL and narrows the list", %{
      conn: conn,
      updated: updated,
      appointed: appointed
    } do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      view
      |> form("#audit-log-filters", filters: %{action: "org_admin_appointed"})
      |> render_change()

      assert_patch(view, ~p"/org/audit?#{%{"action" => "org_admin_appointed"}}")
      assert has_element?(view, "#events-#{appointed.id}")
      refute has_element?(view, "#events-#{updated.id}")
      assert has_element?(view, "#audit-log-clear-filters")
    end

    test "date filters apply inside the Organization", %{
      conn: conn,
      updated: updated,
      appointed: appointed
    } do
      {:ok, view, _html} = live(conn, ~p"/org/audit?from=2026-10-02&to=2026-10-02")

      assert has_element?(view, "#events-#{appointed.id}")
      refute has_element?(view, "#events-#{updated.id}")
    end

    test "export links carry the filters on screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit?action=org_admin_appointed")

      assert view |> element("#audit-log-export-csv") |> render() =~
               "/org/audit/export?action=org_admin_appointed&amp;format=csv"

      assert view |> element("#audit-log-export-json") |> render() =~
               "/org/audit/export?action=org_admin_appointed&amp;format=json"
    end

    test "a filter matching nothing shows the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit?action=sudo_mode_entered")

      assert has_element?(view, "#audit-log-empty")
    end

    test "a tampered cursor falls back to the newest page", %{conn: conn, appointed: appointed} do
      {:ok, view, _html} = live(conn, ~p"/org/audit?cursor=bm90LWEtY3Vyc29y")

      assert has_element?(view, "#events-#{appointed.id}")
      refute has_element?(view, "#audit-log-newest")
    end

    test "never shows a site admin actor's email or IP", %{conn: conn, org_a: org_a} do
      site_admin = admin_fixture()

      by_admin =
        insert_event!("org_admin_appointed", org_a, ~U[2026-10-09 09:00:00.000000Z],
          actor: site_admin,
          ip: "203.0.113.9",
          metadata: %{"user_id" => site_admin.id, "ip" => "203.0.113.9"}
        )

      {:ok, view, html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#events-#{by_admin.id}", "Outside your Organization")
      refute html =~ site_admin.email
      refute html =~ "203.0.113.9"
    end

    test "offers no actor-email filter, so a guessed staff email confirms nothing", %{
      conn: conn,
      org_a: org_a,
      updated: updated,
      appointed: appointed
    } do
      site_admin = admin_fixture()

      by_admin =
        insert_event!("organization_updated", org_a, ~U[2026-10-09 09:00:00.000000Z],
          actor: site_admin
        )

      {:ok, view, _html} = live(conn, ~p"/org/audit?#{%{"actor_email" => site_admin.email}}")

      refute has_element?(view, "#audit-log-filters input[type=email]")
      assert has_element?(view, "#events-#{by_admin.id}")
      assert has_element?(view, "#events-#{updated.id}")
      assert has_element?(view, "#events-#{appointed.id}")
      refute view |> element("#audit-log-export-csv") |> render() =~ "actor_email"
    end

    test "shows a member actor's email", %{conn: conn, org_admin: org_admin, updated: updated} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#events-#{updated.id}", org_admin.email)
    end

    test "links back to the console", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, ~s(#org-audit-log-back[href="/org"]))
    end
  end

  describe "keyset paging" do
    setup :org_admin_setup

    test "pages through the Organization's events only", %{conn: conn, org_a: org_a, org_b: org_b} do
      base = ~U[2026-10-01 00:00:00.000000Z]

      ids =
        for n <- 1..51 do
          insert_event!("organization_updated", org_a, DateTime.add(base, n)).id
        end

      foreign = insert_event!("organization_updated", org_b, DateTime.add(base, 30)).id

      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#events-#{List.last(ids)}")
      refute has_element?(view, "#events-#{hd(ids)}")
      refute has_element?(view, "#events-#{foreign}")

      view |> element("#audit-log-next-page") |> render_click()

      assert has_element?(view, "#events-#{hd(ids)}")
      refute has_element?(view, "#events-#{List.last(ids)}")
      refute has_element?(view, "#events-#{foreign}")
      refute has_element?(view, "#audit-log-next-page")
      assert has_element?(view, "#audit-log-newest")
    end
  end

  describe "an Organization with no events" do
    setup :org_admin_setup

    test "shows the empty state and an empty action list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#audit-log-empty")
      refute view |> element("#audit-log-filters select") |> render() =~ "organization_"
    end
  end
end
