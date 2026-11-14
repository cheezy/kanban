defmodule KanbanWeb.OrgLive.SSOTest do
  # async: false: one test switches :plans_enforced, which is global.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.SSOFixtures

  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.DomainVerification

  @refusal "You must be an org-admin of an Organization to access this page."

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org: org, org_admin: org_admin}
  end

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  describe "access control" do
    test "a member is refused on the server and the refusal is audited", %{conn: conn, org: org} do
      member = user_fixture()
      organization_member_fixture(org, member)

      assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
               live(log_in_user(conn, member), ~p"/org/sso")

      assert flash["error"] == @refusal
      assert [_event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
    end

    test "an org-admin of another Organization only ever sees their own", %{conn: conn, org: org} do
      theirs = domain_fixture(org)
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :org_admin)

      {:ok, lv, html} = live(log_in_user(conn, outsider), ~p"/org/sso")
      refute html =~ theirs.domain

      render_click(lv, "verify_domain", %{"id" => "#{theirs.id}"})
      render_click(lv, "remove_domain", %{"id" => "#{theirs.id}"})
      assert Repo.reload(theirs)
      refute Repo.reload(theirs).verified_at
    end

    test "a visitor is sent to log in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/org/sso")
    end

    test "an org-admin demoted while the page is open is refused on every event",
         %{conn: conn, org: org, org_admin: org_admin} do
      domain = domain_fixture(org)

      events = [
        fn lv ->
          lv |> form("#sso-domain-form", domain: %{domain: "x.example"}) |> render_submit()
        end,
        fn lv -> render_click(lv, "verify_domain", %{"id" => "#{domain.id}"}) end,
        fn lv -> render_click(lv, "remove_domain", %{"id" => "#{domain.id}"}) end,
        fn lv ->
          lv
          |> form("#sso-connection-form", connection: %{issuer: issuer()})
          |> render_change()
        end,
        fn lv ->
          lv
          |> form("#sso-connection-form", connection: %{issuer: issuer(), client_id: "c"})
          |> render_submit()
        end,
        fn lv ->
          lv |> form("#saml-connection-form", saml: %{issuer: "urn:idp"}) |> render_change()
        end,
        fn lv ->
          lv |> form("#saml-connection-form", saml: %{issuer: "urn:idp"}) |> render_submit()
        end
      ]

      for event <- events do
        from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :org_admin])

        {:ok, lv, _html} = live(conn, ~p"/org/sso")
        demote(org_admin)

        assert {:error, {:redirect, %{to: "/boards"}}} = event.(lv)
      end

      assert SSO.list_domains(org.id) == [domain]
      refute SSO.get_oidc_connection(org.id)
      refute SSO.get_saml_connection(org.id)

      assert length(AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)) ==
               7
    end

    test "an org-admin is not locked out when plans are enforced", %{conn: conn} do
      enforce_plans()
      {:ok, _lv, html} = live(conn, ~p"/org/sso")
      refute html =~ "org-sso-locked"
      assert html =~ "sso-domain-form"
    end
  end

  describe "domains" do
    test "adding a domain shows the TXT record to publish", %{conn: conn, org: org} do
      {:ok, lv, html} = live(conn, ~p"/org/sso")
      assert html =~ "sso-no-domains"

      name = unique_domain()
      html = lv |> form("#sso-domain-form", domain: %{domain: name}) |> render_submit()

      [domain] = SSO.list_domains(org.id)
      assert html =~ DomainVerification.record_name(domain)
      assert html =~ DomainVerification.record_value(domain)
      assert has_element?(lv, "#sso-domain-#{domain.id}-pending")
    end

    test "an invalid domain shows the error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      html = lv |> form("#sso-domain-form", domain: %{domain: "nope"}) |> render_submit()
      assert html =~ "must be a domain such as example.com"
    end

    test "a domain another Organization verified is refused", %{conn: conn} do
      shared = verified_domain_fixture(organization_fixture()).domain
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html = lv |> form("#sso-domain-form", domain: %{domain: shared}) |> render_submit()
      assert html =~ "Another Organization has already verified this domain."
    end

    test "verify succeeds when the record is published and explains when it is not",
         %{conn: conn, org: org} do
      published = domain_fixture(org)
      missing = domain_fixture(org, "unpublished.example")
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html = lv |> element("#sso-verify-#{missing.id}") |> render_click()
      assert html =~ "The TXT record was not found."

      html = lv |> element("#sso-verify-#{published.id}") |> render_click()
      assert html =~ "#{published.domain} is verified."
      assert has_element?(lv, "#sso-domain-#{published.id}-verified")
    end

    test "warns while the daily re-check is not finding a verified domain's record",
         %{conn: conn, org: org} do
      domain = verified_domain_fixture(org)
      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      refute has_element?(lv, "#sso-domain-#{domain.id}-failing")
      refute has_element?(lv, "#sso-domain-#{domain.id}-value")

      from(d in Kanban.SSO.OrganizationDomain, where: d.id == ^domain.id)
      |> Repo.update_all(set: [failed_checks: 1, failing_since: ~U[2026-10-20 04:11:00Z]])

      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      assert has_element?(lv, "#sso-domain-#{domain.id}-verified")
      assert has_element?(lv, "#sso-domain-#{domain.id}-failing", "since 2026-10-20")
      assert has_element?(lv, "#sso-domain-#{domain.id}-failing", "the next 2 checks")
      assert has_element?(lv, "#sso-domain-#{domain.id}-value")

      from(d in Kanban.SSO.OrganizationDomain, where: d.id == ^domain.id)
      |> Repo.update_all(set: [failed_checks: 2])

      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      assert has_element?(lv, "#sso-domain-#{domain.id}-failing", "if the next check does not")
    end

    test "remove deletes the domain", %{conn: conn, org: org} do
      domain = domain_fixture(org)
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      lv |> element("#sso-remove-#{domain.id}") |> render_click()
      refute has_element?(lv, "#sso-domain-#{domain.id}")
      assert SSO.list_domains(org.id) == []
    end
  end

  describe "the connection" do
    test "shows the redirect URI and saves the connection", %{conn: conn, org: org} do
      {:ok, lv, html} = live(conn, ~p"/org/sso")
      assert html =~ "/users/sso/callback"
      refute has_element?(lv, "#sso-secret-set")

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{
            issuer: issuer(),
            client_id: "stride",
            client_secret: "brand-new-credential",
            enabled: "true"
          }
        )
        |> render_submit()

      assert html =~ "Single sign-on connection saved."
      assert has_element?(lv, "#sso-secret-set")
      refute html =~ "brand-new-credential"

      connection = SSO.get_oidc_connection(org.id)
      assert connection.client_secret == "brand-new-credential"
      assert connection.enabled
    end

    # D436: clearing Client ID on a saved connection crashed the LiveView.
    test "The SSO LiveView shows a validation error for a blank Client ID and does not crash",
         %{conn: conn, org: org} do
      oidc_connection_fixture(org)
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      for event <- [&render_change/1, &render_submit/1], blank <- ["", "   "] do
        html =
          lv
          |> form("#sso-connection-form", connection: %{client_id: blank})
          |> event.()

        assert html =~ "can&#39;t be blank"
        assert Process.alive?(lv.pid)
      end

      html =
        lv
        |> form("#sso-connection-form", connection: %{issuer: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
      assert Process.alive?(lv.pid)

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{issuer: issuer(), client_id: "renamed-client"}
        )
        |> render_submit()

      assert html =~ "Single sign-on connection saved."
      assert SSO.get_oidc_connection(org.id).client_id == "renamed-client"
    end

    test "A validate_connection event logged at debug level carries no client secret",
         %{conn: conn, org: org} do
      oidc_connection_fixture(org)
      probe = "D436-probe-#{System.unique_integer([:positive])}"
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:ok, lv, _html} = live(conn, ~p"/org/sso")

          lv
          |> form("#sso-connection-form", connection: %{client_id: "", client_secret: probe})
          |> render_change()

          lv
          |> form("#sso-connection-form", connection: %{client_id: "", client_secret: probe})
          |> render_submit()

          assert Process.alive?(lv.pid)
        end)

      assert log =~ "validate_connection"
      assert log =~ "save_connection"
      assert log =~ ~s("client_secret" => "[FILTERED]")
      refute log =~ probe
      refute inspect(Repo.all(ErrorTracker.Occurrence)) =~ probe
    end

    # The fixture resolver raises for raise.example.com, inside the issuer
    # check the save runs.
    test "a raise in save is contained and neither the log nor ErrorTracker holds the typed secret",
         %{conn: conn, org: org} do
      connection = oidc_connection_fixture(org)
      probe = "D436-probe-#{System.unique_integer([:positive])}"
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html =
            lv
            |> form("#sso-connection-form",
              connection: %{
                issuer: "https://raise.example.com",
                client_id: "c",
                client_secret: probe
              }
            )
            |> render_submit()

          assert html =~ "Something went wrong"
        end)

      assert Process.alive?(lv.pid)
      assert log =~ "SSO connection form save failed: RuntimeError"
      refute log =~ probe
      refute log =~ "resolver failed"
      assert SSO.get_oidc_connection(org.id).issuer == connection.issuer

      assert [%ErrorTracker.Error{reason: "SSO connection form save failed: RuntimeError"}] =
               Repo.all(ErrorTracker.Error)

      refute inspect(Repo.all(ErrorTracker.Occurrence)) =~ probe
    end

    test "a failed save leaves no typed client secret in the view state", %{conn: conn, org: org} do
      oidc_connection_fixture(org)
      probe = "D436-probe-#{System.unique_integer([:positive])}"
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      lv
      |> form("#sso-connection-form", connection: %{client_id: "", client_secret: probe})
      |> render_submit()

      refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~
               probe
    end

    test "the stored secret is never rendered, even after a failed save", %{conn: conn, org: org} do
      connection = oidc_connection_fixture(org)
      {:ok, lv, html} = live(conn, ~p"/org/sso")
      refute html =~ connection.client_secret

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{issuer: "not a url", client_secret: "typed-credential"}
        )
        |> render_change()

      refute html =~ "typed-credential"

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{issuer: "not a url", client_secret: "typed-credential"}
        )
        |> render_submit()

      refute html =~ "typed-credential"
      refute html =~ connection.client_secret
      assert SSO.get_oidc_connection(org.id).issuer == connection.issuer
    end

    test "an issuer on a private address is refused", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{
            issuer: "https://internal.example.com",
            client_id: "c",
            client_secret: "s"
          }
        )
        |> render_submit()

      assert html =~ "The issuer URL must be a public https address."
      refute SSO.get_oidc_connection(org.id)
    end
  end

  describe "the SAML connection" do
    setup do
      %{idp: Kanban.SAMLTestHelpers.idp()}
    end

    test "shows Stride's SP details and the metadata download", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      sp = Kanban.SSO.SAML.service_provider(org.id)

      assert lv |> element("#saml-sp-entity-id") |> render() =~ sp.entity_id
      assert lv |> element("#saml-acs-url") |> render() =~ sp.acs_url
      assert has_element?(lv, ~s(#saml-sp-metadata[href="/org/sso/saml/metadata"]))
    end

    test "saves a connection from IdP metadata XML", %{conn: conn, org: org, idp: idp} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html =
        lv
        |> form("#saml-connection-form",
          saml: %{idp_metadata: Kanban.SAMLTestHelpers.idp_metadata(idp.pem), enabled: "true"}
        )
        |> render_submit()

      assert html =~ "SAML connection saved."

      connection = SSO.get_saml_connection(org.id)
      assert connection.issuer == Kanban.SAMLTestHelpers.issuer()
      assert connection.settings["sso_url"] == Kanban.SAMLTestHelpers.sso_url()
      assert [_pem] = connection.settings["certificates"]
      assert connection.enabled

      assert [event] = AuditLog.list_events(action: "sso_connection_updated")
      assert event.metadata["protocol"] == "saml"
      assert event.metadata["credentials_changed"] == true
    end

    test "saves a connection from typed fields and keeps the certificates when left blank",
         %{conn: conn, org: org, idp: idp} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      lv
      |> form("#saml-connection-form",
        saml: %{
          issuer: "urn:example:idp",
          sso_url: "https://login.example.com/saml",
          certificates_pem: idp.pem
        }
      )
      |> render_submit()

      connection = SSO.get_saml_connection(org.id)
      assert connection.issuer == "urn:example:idp"
      refute connection.enabled

      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      lv
      |> form("#saml-connection-form", saml: %{certificates_pem: "", enabled: "true"})
      |> render_submit()

      reloaded = SSO.get_saml_connection(org.id)
      assert reloaded.enabled
      assert reloaded.settings["certificates"] == connection.settings["certificates"]
    end

    test "invalid metadata, URL and certificates show errors and save nothing",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html =
        lv
        |> form("#saml-connection-form", saml: %{idp_metadata: "<not metadata"})
        |> render_submit()

      assert html =~ "is not valid identity provider metadata"

      html =
        lv
        |> form("#saml-connection-form",
          saml: %{
            idp_metadata: "",
            issuer: "urn:example:idp",
            sso_url: "ftp://login.example.com",
            certificates_pem: "not a certificate"
          }
        )
        |> render_submit()

      assert html =~ "must be an https URL"
      assert html =~ "must be one or two RSA certificates"
      refute SSO.get_saml_connection(org.id)
    end
  end

  # D441: a value that is not a string failed the cast but stayed in the
  # changeset params, so the re-rendered input raised and crashed the view.
  describe "malformed form params" do
    setup do
      %{idp: Kanban.SAMLTestHelpers.idp()}
    end

    test "valid connection, SAML and domain saves still work", %{conn: conn, org: org, idp: idp} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      html =
        lv
        |> form("#sso-domain-form", domain: %{domain: "d441-valid.example"})
        |> render_submit()

      assert html =~ "Domain added."

      html =
        lv
        |> form("#sso-connection-form",
          connection: %{
            issuer: issuer(),
            client_id: "d441-client",
            client_secret: "d441-made-up-credential",
            enabled: "true"
          }
        )
        |> render_submit()

      assert html =~ "Single sign-on connection saved."

      html =
        lv
        |> form("#saml-connection-form",
          saml: %{
            issuer: "urn:d441:idp",
            sso_url: "https://login.example.com/saml",
            certificates_pem: idp.pem,
            enabled: "true"
          }
        )
        |> render_submit()

      assert html =~ "SAML connection saved."

      assert [%{domain: "d441-valid.example"}] = SSO.list_domains(org.id)
      assert %{client_id: "d441-client", enabled: true} = SSO.get_oidc_connection(org.id)
      assert %{issuer: "urn:d441:idp", enabled: true} = SSO.get_saml_connection(org.id)
    end

    test "a map-valued issuer, client_id or enabled does not crash the connection form",
         %{conn: conn, org: org} do
      connection = oidc_connection_fixture(org)
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      for event <- ["validate_connection", "save_connection"],
          field <- ["issuer", "client_id"],
          value <- [%{"a" => "1"}, [%{"a" => "1"}]] do
        params = %{"issuer" => issuer(), "client_id" => "c", field => value}
        html = render_hook(lv, event, %{"connection" => params})

        assert Process.alive?(lv.pid)
        assert html =~ "sso-connection-form"
        assert html =~ "can&#39;t be blank"
      end

      assert Repo.reload(connection).client_id == connection.client_id

      # The checkbox sends "true" or "false"; anything else keeps the stored
      # value, so a blank enabled can no longer reach the NOT NULL column.
      for event <- ["validate_connection", "save_connection"],
          value <- [%{"a" => "1"}, ["true"], "yes", ""] do
        params = %{"issuer" => issuer(), "client_id" => "c", "enabled" => value}
        html = render_hook(lv, event, %{"connection" => params})

        assert Process.alive?(lv.pid)
        assert html =~ "sso-connection-form"
        assert Repo.reload(connection).enabled
      end

      # A nested map in the secret field is ignored, and the stored secret kept.
      for event <- ["validate_connection", "save_connection"] do
        params = %{"issuer" => issuer(), "client_id" => "c", "client_secret" => %{"a" => "1"}}
        render_hook(lv, event, %{"connection" => params})
        assert Process.alive?(lv.pid)
      end

      assert Repo.reload(connection).client_secret == connection.client_secret
    end

    test "a map-valued SAML field does not crash the SAML form", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      base = %{"issuer" => "urn:d441:idp", "sso_url" => "https://login.example.com/saml"}

      for event <- ["validate_saml", "save_saml"],
          field <- ["issuer", "sso_url", "certificates_pem", "idp_metadata", "enabled"],
          value <- [%{"a" => "1"}, [%{"a" => "1"}]] do
        html = render_hook(lv, event, %{"saml" => Map.put(base, field, value)})

        assert Process.alive?(lv.pid)
        assert html =~ "saml-connection-form"
        if field in ["issuer", "sso_url"], do: assert(html =~ "can&#39;t be blank")
      end

      refute SSO.get_saml_connection(org.id)
    end

    test "a map-valued domain does not crash the domain form", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      for value <- [%{"a" => "1"}, [%{"a" => "1"}]] do
        html = render_hook(lv, "add_domain", %{"domain" => %{"domain" => value}})

        assert Process.alive?(lv.pid)
        assert html =~ "sso-domain-form"
        assert html =~ "can&#39;t be blank"
      end

      assert SSO.list_domains(org.id) == []
    end

    test "a list or integer field value is treated as blank", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      for value <- [42, ["d441.example"], nil] do
        payloads = [
          {"add_domain", %{"domain" => %{"domain" => value}}},
          {"validate_connection",
           %{"connection" => %{"issuer" => issuer(), "client_id" => value}}},
          {"save_connection", %{"connection" => %{"issuer" => value, "client_id" => "c"}}},
          {"validate_saml", %{"saml" => %{"issuer" => "urn:d441:idp", "sso_url" => value}}},
          {"save_saml", %{"saml" => %{"issuer" => value, "sso_url" => "https://x.example.com"}}}
        ]

        for {event, payload} <- payloads do
          html = render_hook(lv, event, payload)

          assert Process.alive?(lv.pid)
          assert html =~ "can&#39;t be blank"
        end
      end

      assert SSO.list_domains(org.id) == []
      refute SSO.get_oidc_connection(org.id)
      refute SSO.get_saml_connection(org.id)
    end

    test "a missing or non-map saml or domain param is ignored", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/sso")

      events = [
        {"add_domain", "domain"},
        {"validate_connection", "connection"},
        {"save_connection", "connection"},
        {"validate_saml", "saml"},
        {"save_saml", "saml"}
      ]

      for {event, key} <- events, payload <- [%{}, %{key => "x"}, %{key => nil}, %{key => [1]}] do
        assert render_hook(lv, event, payload) =~ "sso-domain-form"
        assert Process.alive?(lv.pid)
      end

      assert SSO.list_domains(org.id) == []
      refute SSO.get_oidc_connection(org.id)
      refute SSO.get_saml_connection(org.id)
      assert Repo.all(ErrorTracker.Error) == []
    end

    test "a demoted admin sending malformed params is refused and audited",
         %{conn: conn, org: org, org_admin: org_admin} do
      events =
        for {event, key} <- [
              {"add_domain", "domain"},
              {"validate_connection", "connection"},
              {"save_connection", "connection"},
              {"validate_saml", "saml"},
              {"save_saml", "saml"}
            ],
            payload <- [%{key => "not a map"}, %{key => %{"issuer" => %{"a" => "1"}}}] do
          {event, payload}
        end

      for {event, payload} <- events do
        from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :org_admin])

        {:ok, lv, _html} = live(conn, ~p"/org/sso")
        demote(org_admin)

        assert {:error, {:redirect, %{to: "/boards"}}} = render_hook(lv, event, payload)
      end

      assert SSO.list_domains(org.id) == []
      refute SSO.get_oidc_connection(org.id)

      assert length(AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)) ==
               length(events)
    end
  end

  test "the console links to the page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/org")
    assert has_element?(lv, "#org-sso-link")
  end
end

defmodule KanbanWeb.OrgLive.SSOCrashReportTest do
  @moduledoc """
  The crash report of the `/org/sso` page after a typed client secret
  (D441). Not async: it sets the global Logger level, and the crash report
  prints the last message at every level and the LiveView's state at
  `:debug`.
  """
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.Repo

  setup %{conn: conn} do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)
    oidc_connection_fixture(org)

    original = Logger.level()
    on_exit(fn -> Logger.configure(level: original) end)

    %{conn: log_in_user(conn, org_admin)}
  end

  test "a crash after a typed client secret keeps the secret out of the log, ErrorTracker and the view state",
       %{conn: conn} do
    Process.flag(:trap_exit, true)

    for level <- [:info, :debug] do
      Logger.configure(level: level)
      probe = "D441-probe-#{System.unique_integer([:positive])}"
      {:ok, lv, _html} = live(conn, ~p"/org/sso")
      ref = Process.monitor(lv.pid)

      log =
        capture_log([level: level], fn ->
          # Before D441 these map-valued events crashed the view at render,
          # and the crash report printed the payload, probe secret included.
          for event <- ["validate_connection", "save_connection"] do
            render_hook(lv, event, %{
              "connection" => %{
                "issuer" => issuer(),
                "client_id" => %{"a" => "1"},
                "client_secret" => probe,
                "enabled" => %{"a" => "1"}
              }
            })

            assert Process.alive?(lv.pid)
          end

          refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~
                   probe

          # The page defines no handle_cast/2, so this crashes the view.
          GenServer.cast(lv.pid, :d441_crash)
          assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
        end)

      assert log =~ "d441_crash"
      refute log =~ probe
      refute inspect(Repo.all(ErrorTracker.Occurrence)) =~ probe
    end
  end
end
