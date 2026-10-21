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

  test "the console links to the page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/org")
    assert has_element?(lv, "#org-sso-link")
  end
end
