defmodule KanbanWeb.OrgLive.AuditLogTest do
  # async: false — the signing key tests replace the application config of
  # Kanban.AuditLog.Signing, which is global.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Signing
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

  describe "an org-admin disabled while the audit log is open" do
    setup :org_admin_setup

    test "is refused on the next patch", %{conn: conn, org_admin: org_admin} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      org_admin
      |> Kanban.Accounts.User.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:error, {:redirect, %{to: "/boards"}}} =
               render_patch(view, ~p"/org/audit?cursor=anything")
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
      {:ok, view, _html} = live(conn, ~p"/org/audit?from=2030-01-01")

      assert has_element?(view, "#audit-log-empty")
    end

    test "an action not in this Organization's events is not applied, so the list and the select agree",
         %{conn: conn, updated: updated, appointed: appointed, other: other} do
      for action <- ["no_such_action", "organization_created"] do
        {:ok, view, _html} = live(conn, ~p"/org/audit?action=#{action}")

        refute has_element?(view, "#audit-log-empty"), action
        assert has_element?(view, "#events-#{updated.id}"), action
        assert has_element?(view, "#events-#{appointed.id}"), action
        refute has_element?(view, "#events-#{other.id}"), action
        refute has_element?(view, "#audit-log-filters option[selected]"), action
        refute has_element?(view, "#audit-log-clear-filters"), action
        refute view |> element("#audit-log-export-json") |> render() =~ action
      end
    end

    # The export reads the known actions per request, so the page must not keep
    # the set it read at mount: a patched URL filters as its export does.
    test "an action that first occurs after mount is applied when the URL is patched",
         %{conn: conn, org_a: org_a, updated: updated} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      exported = insert_event!("org_audit_log_exported", org_a, ~U[2026-10-05 09:00:00.000000Z])
      render_patch(view, ~p"/org/audit?action=org_audit_log_exported")

      assert has_element?(view, "#events-#{exported.id}")
      refute has_element?(view, "#events-#{updated.id}")

      assert has_element?(
               view,
               "#audit-log-filters option[selected][value=org_audit_log_exported]"
             )

      assert view |> element("#audit-log-export-json") |> render() =~
               "action=org_audit_log_exported"
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

    test "shows actions by their translated labels and filters by the raw action", %{
      conn: conn,
      appointed: appointed
    } do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#events-#{appointed.id} .badge", "Org-admin appointed")
      assert has_element?(view, ~s(#events-#{appointed.id} .badge[title="org_admin_appointed"]))

      assert has_element?(
               view,
               ~s(#audit-log-filters option[value="org_admin_appointed"]),
               "Org-admin appointed"
             )

      {:ok, fr_view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> live(~p"/org/audit")

      assert has_element?(
               fr_view,
               "#events-#{appointed.id} .badge",
               "Administrateur d'organisation nommé"
             )
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

  describe "the signed export and the signing key" do
    setup :org_admin_setup

    setup %{org_a: org_a} do
      saved = Application.fetch_env(:kanban, Signing)

      on_exit(fn ->
        case saved do
          {:ok, config} -> Application.put_env(:kanban, Signing, config)
          :error -> Application.delete_env(:kanban, Signing)
        end
      end)

      insert_event!("org_admin_appointed", org_a, ~U[2026-10-02 09:00:00.000000Z])
      %{saved_signing: saved}
    end

    defp signed_href(view) do
      [href] =
        view
        |> element("#audit-log-export-signed")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("href")

      href
    end

    defp text_of(view, selector) do
      view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
    end

    test "an org-admin sees Export signed (.zip) beside Export CSV and Export JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#audit-log-export-csv", "Export CSV")
      assert has_element?(view, "#audit-log-export-json", "Export JSON")
      assert has_element?(view, "a#audit-log-export-signed.btn", "Export signed (.zip)")
      assert has_element?(view, "#audit-log-export-signed .hero-arrow-down-tray.size-4")
      assert has_element?(view, "#audit-log-signing-key")
      refute has_element?(view, "#audit-log-signing-off")
    end

    test "the signed button href carries the filters, format=csv and signed=true but no cursor",
         %{conn: conn, org_a: org_a} do
      base = ~U[2026-09-01 00:00:00.000000Z]
      for n <- 1..51, do: insert_event!("organization_updated", org_a, DateTime.add(base, n))

      {:ok, view, _html} = live(conn, ~p"/org/audit?action=organization_updated")
      view |> element("#audit-log-next-page") |> render_click()

      assert has_element?(view, "#audit-log-newest")

      assert signed_href(view) ==
               "/org/audit/export?action=organization_updated&format=csv&signed=true"
    end

    test "changing a filter updates the signed button href", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert signed_href(view) == "/org/audit/export?format=csv&signed=true"

      view
      |> form("#audit-log-filters", filters: %{action: "org_admin_appointed"})
      |> render_change()

      assert signed_href(view) ==
               "/org/audit/export?action=org_admin_appointed&format=csv&signed=true"

      render_patch(view, ~p"/org/audit?action=org_admin_appointed&from=2026-10-01&to=2026-10-03")

      assert signed_href(view) ==
               "/org/audit/export?action=org_admin_appointed&format=csv&from=2026-10-01&signed=true&to=2026-10-03"
    end

    test "the key panel shows the key id, the fingerprint and both links", %{conn: conn} do
      %{key_id: key_id, fingerprint: fingerprint, public_key: public_key} = Signing.current_key()
      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/

      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "#audit-log-signing-key-title", "Signing key")
      assert text_of(view, "#audit-log-signing-key-id") == key_id
      assert text_of(view, "#audit-log-signing-key-fingerprint") == fingerprint
      assert has_element?(view, "#audit-log-signing-key-fingerprint.break-all")
      assert has_element?(view, "#audit-log-signing-key-advice", "outside Stride")

      assert has_element?(
               view,
               ~s(#audit-log-signing-keys-link[href="/.well-known/stride-audit-signing-keys"])
             )

      assert has_element?(
               view,
               ~s(#audit-log-signing-key-pem-link[href="/.well-known/stride-audit-signing-keys?format=pem&kid=#{key_id}"])
             )

      # Public material only: the raw public key never reaches the page.
      html = view |> element("#audit-log-signing-key") |> render()
      refute html =~ Base.url_encode64(public_key, padding: false)
      refute html =~ Base.encode64(public_key)
    end

    test "with signing off the button is disabled, the note shows and the panel is absent", %{
      conn: conn,
      saved_signing: saved
    } do
      Application.put_env(:kanban, Signing, [])
      refute Signing.enabled?()

      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(
               view,
               "button#audit-log-export-signed[disabled]",
               "Export signed (.zip)"
             )

      refute has_element?(view, "#audit-log-export-signed[href]")
      refute has_element?(view, "a#audit-log-export-signed")

      assert has_element?(
               view,
               "#audit-log-signing-off",
               "Signed exports are not set up on this server."
             )

      refute has_element?(view, "#audit-log-signing-key")
      refute has_element?(view, "#audit-log-signing-keys-link")
      assert has_element?(view, "#audit-log-export-csv[href]")

      # Signing back on: the next mount (a restart, or a reload) shows it again.
      {:ok, config} = saved
      Application.put_env(:kanban, Signing, config)

      {:ok, view, _html} = live(conn, ~p"/org/audit")

      assert has_element?(view, "a#audit-log-export-signed[href]")
      assert has_element?(view, "#audit-log-signing-key")
      refute has_element?(view, "#audit-log-signing-off")
    end

    test "the new labels render translated in every supported locale", %{conn: conn} do
      checks = [
        {"#audit-log-export-signed", "Export signed (.zip)"},
        {"#audit-log-signing-key-title", "Signing key"},
        {"#audit-log-signing-key dl", "Key ID"},
        {"#audit-log-signing-key dl", "Fingerprint (SHA-256)"},
        {"#audit-log-signing-keys-link", "Public key set"},
        {"#audit-log-signing-key-pem-link", "This key as PEM"},
        {"#audit-log-signing-key-advice",
         "Signed exports are signed with this key. Record its fingerprint somewhere outside Stride, so you can later confirm that the key that verifies an export is this one."}
      ]

      for locale <- ~w(de en es fr ja pt zh) do
        {:ok, view, _html} =
          conn
          |> Plug.Test.init_test_session(%{"locale" => locale})
          |> live(~p"/org/audit")

        for {selector, msgid} <- checks do
          translated =
            Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
              Gettext.gettext(KanbanWeb.Gettext, msgid)
            end)

          if locale != "en", do: assert(translated != msgid, "#{locale} lacks #{msgid}")
          assert has_element?(view, selector, translated), "#{locale}: #{msgid}"
        end
      end
    end

    test "two org-admins viewing at once see the same key id", %{conn: conn, org_a: org_a} do
      second_admin = user_fixture()
      organization_member_fixture(org_a, second_admin, :org_admin)
      %{key_id: key_id} = Signing.current_key()

      {:ok, first, _html} = live(conn, ~p"/org/audit")
      {:ok, second, _html} = live(log_in_user(build_conn(), second_admin), ~p"/org/audit")

      assert text_of(first, "#audit-log-signing-key-id") == key_id
      assert text_of(second, "#audit-log-signing-key-id") == key_id
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
