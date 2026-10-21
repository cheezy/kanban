defmodule Kanban.SSOTest do
  # async: false because some tests switch :plans_enforced, which is global.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.SSOFixtures

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.OrganizationDomain
  alias Kanban.SSO.SSOConnection

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    %{organization: organization, org_admin: org_admin}
  end

  describe "check_access/2" do
    test "goes through Kanban.Plans and follows :plans_enforced", %{org_admin: org_admin} do
      free_user = user_fixture()

      assert :ok = SSO.check_access(free_user, :live_view)

      enforce_plans()
      assert {:error, {:plan_required, :sso}} = SSO.check_access(free_user, :live_view)
      assert :ok = SSO.check_access(org_admin, :live_view)
    end
  end

  describe "domains" do
    test "an org-admin adds a domain, which starts unverified with a token", ctx do
      assert {:ok, %OrganizationDomain{} = domain} =
               SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => " Acme.Example "})

      assert domain.domain == "acme.example"
      assert is_nil(domain.verified_at)
      assert byte_size(domain.verification_token) >= 32
      assert [^domain] = SSO.list_domains(ctx.organization.id)
    end

    test "adding an invalid or duplicate domain returns a changeset", ctx do
      assert {:error, %Ecto.Changeset{}} =
               SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => "nope"})

      {:ok, _domain} =
        SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => "a.example"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => "A.example"})

      assert errors_on(changeset).domain != []
    end

    test "verification succeeds only when the TXT record is present", ctx do
      {:ok, domain} =
        SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => "absent.example"})

      assert {:error, :record_not_found} =
               SSO.verify_domain(ctx.org_admin, ctx.organization.id, domain.id)

      {:ok, present} =
        SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => unique_domain()})

      assert {:ok, verified} = SSO.verify_domain(ctx.org_admin, ctx.organization.id, present.id)
      assert verified.verified_at
      assert SSO.domain_verified_by?(ctx.organization.id, present.domain)
      refute SSO.domain_verified_by?(ctx.organization.id, "absent.example")

      assert [event] = AuditLog.list_events(action: "organization_domain_verified")
      assert event.organization_id == ctx.organization.id

      assert {:ok, ^verified} = SSO.verify_domain(ctx.org_admin, ctx.organization.id, present.id)
    end

    test "a domain already verified by another Organization is refused", ctx do
      shared = unique_domain()
      other = organization_fixture()
      verified_domain_fixture(other, shared)

      assert {:error, :domain_taken} =
               SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => shared})
    end

    test "when two Organizations claim a domain, the first verification wins", ctx do
      shared = unique_domain()
      {:ok, mine} = SSO.add_domain(ctx.org_admin, ctx.organization.id, %{"domain" => shared})

      other = organization_fixture()
      theirs = verified_domain_fixture(other, shared)
      assert theirs.verified_at

      assert {:error, :domain_taken} =
               SSO.verify_domain(ctx.org_admin, ctx.organization.id, mine.id)

      refute Repo.reload(mine).verified_at
    end

    test "another Organization's domain id is not found", ctx do
      theirs = domain_fixture(organization_fixture())

      assert {:error, :not_found} =
               SSO.verify_domain(ctx.org_admin, ctx.organization.id, theirs.id)

      assert {:error, :not_found} =
               SSO.remove_domain(ctx.org_admin, ctx.organization.id, theirs.id)

      assert {:error, :not_found} = SSO.remove_domain(ctx.org_admin, ctx.organization.id, "x")
      assert Repo.reload(theirs)
    end

    test "an org-admin removes a domain", ctx do
      domain = domain_fixture(ctx.organization)

      assert {:ok, _removed} =
               SSO.remove_domain(ctx.org_admin, ctx.organization.id, "#{domain.id}")

      assert SSO.list_domains(ctx.organization.id) == []
    end

    test "members, other org-admins and disabled org-admins are refused", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :org_admin)

      disabled = user_fixture()
      organization_member_fixture(ctx.organization, disabled, :org_admin)
      disabled |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      domain = domain_fixture(ctx.organization)

      for actor <- [member, outsider, disabled] do
        assert {:error, :unauthorized} =
                 SSO.add_domain(actor, ctx.organization.id, %{"domain" => "x.example"})

        assert {:error, :unauthorized} = SSO.verify_domain(actor, ctx.organization.id, domain.id)
        assert {:error, :unauthorized} = SSO.remove_domain(actor, ctx.organization.id, domain.id)

        assert {:error, :unauthorized} =
                 SSO.save_oidc_connection(actor, ctx.organization.id, %{"issuer" => issuer()})
      end
    end
  end

  describe "connections" do
    @attrs %{
      "issuer" => "https://idp.example.com",
      "client_id" => "client",
      "client_secret" => "first-credential",
      "enabled" => "true"
    }

    test "an org-admin saves a connection whose secret is stored encrypted", ctx do
      assert {:ok, %SSOConnection{} = connection} =
               SSO.save_oidc_connection(ctx.org_admin, ctx.organization.id, @attrs)

      assert connection.client_secret == "first-credential"
      assert connection.enabled
      assert connection.updated_by_id == ctx.org_admin.id

      %{rows: [[raw]]} =
        Repo.query!("SELECT client_secret FROM sso_connections WHERE id = $1", [connection.id])

      assert is_binary(raw)
      refute raw =~ "first-credential"
      refute inspect(connection) =~ "first-credential"

      assert [event] = AuditLog.list_events(action: "sso_connection_updated")
      assert event.metadata["credentials_changed"] == true
      refute inspect(event.metadata) =~ "first-credential"
    end

    test "a blank secret keeps the stored one", ctx do
      {:ok, _connection} = SSO.save_oidc_connection(ctx.org_admin, ctx.organization.id, @attrs)

      assert {:ok, updated} =
               SSO.save_oidc_connection(ctx.org_admin, ctx.organization.id, %{
                 "issuer" => "https://login.example.com",
                 "client_id" => "client",
                 "client_secret" => "  "
               })

      assert updated.client_secret == "first-credential"
      assert updated.issuer == "https://login.example.com"
    end

    test "a new connection needs a secret and an https issuer", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               SSO.save_oidc_connection(ctx.org_admin, ctx.organization.id, %{
                 "issuer" => "http://idp.example.com",
                 "client_id" => "client"
               })

      errors = errors_on(changeset)
      assert errors.client_secret != []
      assert errors.issuer != []
      assert changeset.action

      for bad <- ["not a url", "https://user:pw@idp.example.com", "https://idp.example.com/?a=1"] do
        assert {:error, %Ecto.Changeset{}} =
                 SSO.save_oidc_connection(
                   ctx.org_admin,
                   ctx.organization.id,
                   Map.put(@attrs, "issuer", bad)
                 )
      end
    end

    test "an issuer on a private address is refused", ctx do
      assert {:error, :unsafe_issuer} =
               SSO.save_oidc_connection(
                 ctx.org_admin,
                 ctx.organization.id,
                 Map.put(@attrs, "issuer", "https://internal.example.com")
               )

      assert {:error, :unsafe_issuer} =
               SSO.save_oidc_connection(
                 ctx.org_admin,
                 ctx.organization.id,
                 Map.put(@attrs, "issuer", "https://unknown-host.example.com")
               )

      refute SSO.get_oidc_connection(ctx.organization.id)
    end

    test "pinned_request sends a checked URL to the address it resolved to" do
      assert {:ok, options} = SSO.pinned_request("https://idp.example.com/jwks")
      assert options[:url] == "https://93.184.216.34/jwks"
      assert options[:headers] == [{"host", "idp.example.com"}]
      assert options[:connect_options] == [hostname: "idp.example.com"]

      assert {:ok, options} = SSO.pinned_request("https://idp.example.com:8443/token")
      assert options[:url] == "https://93.184.216.34:8443/token"
      assert options[:headers] == [{"host", "idp.example.com:8443"}]

      assert {:error, :unsafe_url} = SSO.pinned_request("https://internal.example.com/jwks")
      assert {:error, :unsafe_url} = SSO.pinned_request("http://idp.example.com/jwks")
    end

    test "allow_private_issuers skips the address check and allows http", ctx do
      previous = Application.get_env(:kanban, SSO)
      Application.put_env(:kanban, SSO, Keyword.put(previous || [], :allow_private_issuers, true))
      on_exit(fn -> Application.put_env(:kanban, SSO, previous) end)

      assert SSO.allow_private_issuers?()
      assert :ok = SSO.guard_url("http://localhost:8080/realms/dev")

      assert {:ok, [url: "http://localhost:8080/realms/dev"]} =
               SSO.pinned_request("http://localhost:8080/realms/dev")

      assert {:ok, _connection} =
               SSO.save_oidc_connection(
                 ctx.org_admin,
                 ctx.organization.id,
                 Map.put(@attrs, "issuer", "http://localhost:8080/realms/dev")
               )
    end

    test "connection_for_domain finds the enabled connection of the verifying Organization",
         ctx do
      domain = verified_domain_fixture(ctx.organization)
      connection = oidc_connection_fixture(ctx.organization)

      assert {:ok, %SSOConnection{id: id}} =
               domain.domain |> String.upcase() |> SSO.connection_for_domain()

      assert id == connection.id
      assert {:ok, ^connection} = SSO.get_enabled_oidc_connection(connection.id)

      assert {:error, :not_found} = SSO.connection_for_domain("unclaimed.example")
      assert {:error, :not_found} = SSO.connection_for_domain(nil)

      connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
      assert {:error, :not_found} = SSO.connection_for_domain(domain.domain)
      assert {:error, :not_found} = SSO.get_enabled_oidc_connection(connection.id)
      assert {:error, :not_found} = SSO.get_enabled_oidc_connection("1")
    end

    test "an unverified domain does not route to a connection", ctx do
      domain = domain_fixture(ctx.organization)
      oidc_connection_fixture(ctx.organization)

      assert {:error, :not_found} = SSO.connection_for_domain(domain.domain)
    end

    test "change_oidc_connection builds form changesets", ctx do
      assert %Ecto.Changeset{} = SSO.change_oidc_connection(nil)
      connection = oidc_connection_fixture(ctx.organization)
      assert %Ecto.Changeset{data: ^connection} = SSO.change_oidc_connection(connection, %{})
    end
  end

  describe "user_has_identity?/1" do
    test "is true once the user has an identity", ctx do
      user = user_fixture()
      refute SSO.user_has_identity?(user)

      identity_fixture(user, oidc_connection_fixture(ctx.organization), "sub-1")
      assert SSO.user_has_identity?(user)
    end
  end
end
