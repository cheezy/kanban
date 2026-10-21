defmodule Kanban.SSO.ProvisioningTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures
  import Kanban.SSOFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM.Lifecycle
  alias Kanban.SCIM.UserLink
  alias Kanban.SSO.Provisioning
  alias Kanban.SSO.UserIdentity
  alias Kanban.Workspaces.Workspace

  setup do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization)
    connection = oidc_connection_fixture(organization)
    %{organization: organization, domain: domain.domain, connection: connection}
  end

  defp claims(domain, overrides) do
    Map.merge(
      %{
        "sub" => "sub-#{System.unique_integer([:positive])}",
        "email" => "person#{System.unique_integer([:positive])}@#{domain}",
        "email_verified" => true,
        "name" => "Pat Person"
      },
      overrides
    )
  end

  defp scim_deprovision(organization, user) do
    {token, _plaintext} = scim_token_fixture(organization)
    {:ok, _link} = UserLink.upsert(organization.id, user.id, nil)
    {:ok, _sessions} = Lifecycle.deprovision(token, user, :deactivated)
    token
  end

  defp identities(user),
    do: from(i in UserIdentity, where: i.user_id == ^user.id) |> Repo.all()

  describe "a new user" do
    test "is created confirmed, without a password, with a member membership", ctx do
      claims = claims(ctx.domain, %{"email" => "New.Person@" <> String.upcase(ctx.domain)})

      assert {:ok, %User{} = user, :provisioned} = Provisioning.provision(ctx.connection, claims)

      assert user.email == "new.person@" <> ctx.domain
      assert user.confirmed_at
      assert is_nil(Repo.reload(user).hashed_password)
      assert user.name == "Pat Person"

      assert %OrganizationMember{role: :member, organization_id: org_id} =
               Organizations.get_membership(user)

      assert org_id == ctx.organization.id
      assert %Workspace{personal: true} = Kanban.Workspaces.get_personal_workspace(user)
      assert [%UserIdentity{subject: sub, issuer: issuer}] = identities(user)
      assert sub == claims["sub"]
      assert issuer == ctx.connection.issuer

      assert [_event] = AuditLog.list_events(action: "sso_user_provisioned")
    end

    test "drops a name Stride would refuse rather than failing", ctx do
      claims = claims(ctx.domain, %{"name" => "Pat & Co"})

      assert {:ok, user, :provisioned} = Provisioning.provision(ctx.connection, claims)
      assert is_nil(user.name)
    end

    test "is refused for a domain the Organization has not verified", ctx do
      unverified = domain_fixture(ctx.organization)

      for email <- ["pat@#{unverified.domain}", "pat@elsewhere.example", "not-an-email", nil] do
        assert {:error, :domain_not_verified} =
                 Provisioning.provision(ctx.connection, claims(ctx.domain, %{"email" => email}))
      end

      refute Accounts.get_user_by_email("pat@#{unverified.domain}")
    end

    test "is refused for a domain verified by another Organization", ctx do
      other = organization_fixture()
      other_domain = verified_domain_fixture(other)

      assert {:error, :domain_not_verified} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => "pat@" <> other_domain.domain})
               )
    end

    test "is refused when email_verified is false or missing", ctx do
      for value <- [false, "false", nil] do
        claims = claims(ctx.domain, %{"email_verified" => value})
        assert {:error, :email_not_verified} = Provisioning.provision(ctx.connection, claims)
        refute Accounts.get_user_by_email(claims["email"])
      end
    end

    test "accepts email_verified sent as a string", ctx do
      assert {:ok, _user, :provisioned} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email_verified" => "true"})
               )
    end

    test "keeps a plus-address as its own mailbox", ctx do
      existing = user_fixture(%{email: "pat@#{ctx.domain}"})

      assert {:ok, user, :provisioned} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => "pat+sso@#{ctx.domain}"})
               )

      refute user.id == existing.id
    end

    test "is refused without a subject", ctx do
      for sub <- [nil, "", 42] do
        assert {:error, :invalid_claims} =
                 Provisioning.provision(ctx.connection, claims(ctx.domain, %{"sub" => sub}))
      end

      assert {:error, :invalid_claims} = Provisioning.provision(ctx.connection, "not a map")
    end
  end

  describe "an existing account" do
    test "is linked and made a member when it has no membership", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      claims = claims(ctx.domain, %{"email" => "PAT@#{ctx.domain}"})

      assert {:ok, linked, :linked} = Provisioning.provision(ctx.connection, claims)
      assert linked.id == user.id
      assert Organizations.member?(user, ctx.organization.id)
      assert [_identity] = identities(user)
      assert Repo.reload(user).hashed_password, "a confirmed account keeps its password"
      assert [_event] = AuditLog.list_events(action: "sso_account_linked")
    end

    test "is found by an email whose domain has a trailing dot", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      claims = claims(ctx.domain, %{"email" => "Pat@#{ctx.domain}."})

      assert {:ok, linked, :linked} = Provisioning.provision(ctx.connection, claims)
      assert linked.id == user.id
    end

    test "keeps an org-admin's role", ctx do
      user = user_fixture(%{email: "admin@#{ctx.domain}"})
      organization_member_fixture(ctx.organization, user, :org_admin)

      assert {:ok, _user, :linked} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => user.email})
               )

      assert %OrganizationMember{role: :org_admin} = Organizations.get_membership(user)
    end

    test "is not linked while SCIM has it deprovisioned", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      organization_member_fixture(ctx.organization, user)
      scim_deprovision(ctx.organization, user)

      claims = claims(ctx.domain, %{"email" => user.email})
      assert {:error, :scim_deprovisioned} = Provisioning.provision(ctx.connection, claims)
      refute Organizations.member?(user, ctx.organization.id)
      assert identities(user) == []
    end

    test "is not linked when email_verified is false", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      claims = claims(ctx.domain, %{"email" => user.email, "email_verified" => false})

      assert {:error, :email_not_verified} = Provisioning.provision(ctx.connection, claims)
      assert identities(user) == []
      refute Organizations.member?(user, ctx.organization.id)
    end

    test "an unconfirmed account is confirmed and loses its password and tokens", ctx do
      user = unconfirmed_user_fixture(%{email: "squatter@#{ctx.domain}"})
      user = set_password(user)
      _token = Accounts.generate_user_session_token(user)

      assert {:ok, linked, :linked} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => user.email})
               )

      reloaded = Repo.reload(linked)
      assert reloaded.confirmed_at
      assert is_nil(reloaded.hashed_password)
      assert from(t in UserToken, where: t.user_id == ^user.id) |> Repo.all() == []
    end

    test "is refused when it belongs to another Organization, and nothing changes", ctx do
      other = organization_fixture()
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      organization_member_fixture(other, user)

      assert {:error, :membership_conflict} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => user.email})
               )

      assert %OrganizationMember{organization_id: other_id} = Organizations.get_membership(user)
      assert other_id == other.id
      assert identities(user) == []
    end

    test "is refused when disabled", ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :user_disabled} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => user.email})
               )

      assert identities(user) == []
    end

    test "is refused when it is a site admin, and nothing is written", ctx do
      admin = admin_fixture(%{email: "boss@#{ctx.domain}"})

      assert {:error, :site_admin} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"email" => admin.email})
               )

      assert identities(admin) == []
      refute Organizations.member?(admin, ctx.organization.id)
      assert Repo.reload(admin).hashed_password
    end
  end

  describe "an existing account with two-factor on" do
    setup ctx do
      user = user_fixture(%{email: "pat@#{ctx.domain}"})
      Kanban.TwoFactorHelpers.enroll(user)
      %{user: user, claims: claims(ctx.domain, %{"email" => user.email})}
    end

    test "is not linked before its code: provision asks for it and writes nothing", ctx do
      assert {:two_factor_required, %User{id: id}} =
               Provisioning.provision(ctx.connection, ctx.claims)

      assert id == ctx.user.id
      assert identities(ctx.user) == []
      refute Organizations.member?(ctx.user, ctx.organization.id)
      assert AuditLog.list_events(action: "sso_account_linked") == []
    end

    test "a SCIM-deprovisioned account is refused without asking for a code", ctx do
      organization_member_fixture(ctx.organization, ctx.user)
      scim_deprovision(ctx.organization, ctx.user)

      assert {:error, :scim_deprovisioned} = Provisioning.provision(ctx.connection, ctx.claims)
    end

    test "is linked once the code was accepted, and later sign-ins are not asked again",
         ctx do
      subject = ctx.claims["sub"]

      assert {:ok, linked, :linked} =
               Provisioning.link_after_two_factor(ctx.connection, subject, ctx.user.id)

      assert linked.id == ctx.user.id
      assert Organizations.member?(ctx.user, ctx.organization.id)
      assert [%UserIdentity{subject: ^subject}] = identities(ctx.user)
      assert [_event] = AuditLog.list_events(action: "sso_account_linked")

      assert {:ok, again, :existing_identity} =
               Provisioning.provision(ctx.connection, ctx.claims)

      assert again.id == ctx.user.id
    end

    test "a second link for the same subject is refused", ctx do
      subject = ctx.claims["sub"]

      assert {:ok, _user, :linked} =
               Provisioning.link_after_two_factor(ctx.connection, subject, ctx.user.id)

      assert {:error, :invalid_claims} =
               Provisioning.link_after_two_factor(ctx.connection, subject, ctx.user.id)
    end

    test "re-reads the account: disabled, site admin, moved off the domain or gone", ctx do
      subject = ctx.claims["sub"]

      assert {:error, :invalid_claims} =
               Provisioning.link_after_two_factor(ctx.connection, subject, -1)

      assert {:error, :invalid_claims} =
               Provisioning.link_after_two_factor(ctx.connection, "", ctx.user.id)

      {:ok, moved} =
        ctx.user |> Ecto.Changeset.change(email: "pat@elsewhere.example") |> Repo.update()

      assert {:error, :domain_not_verified} =
               Provisioning.link_after_two_factor(ctx.connection, subject, moved.id)

      admin = admin_fixture(%{email: "boss@#{ctx.domain}"})

      assert {:error, :site_admin} =
               Provisioning.link_after_two_factor(ctx.connection, subject, admin.id)

      disabled = user_fixture(%{email: "gone@#{ctx.domain}"})
      disabled |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :user_disabled} =
               Provisioning.link_after_two_factor(ctx.connection, subject, disabled.id)

      assert identities(ctx.user) == []
    end

    test "an identity linked before two-factor was turned on is not asked", ctx do
      other = user_fixture(%{email: "lee@#{ctx.domain}"})
      claims = claims(ctx.domain, %{"email" => other.email})
      assert {:ok, _user, :linked} = Provisioning.provision(ctx.connection, claims)

      Kanban.TwoFactorHelpers.enroll(other)

      assert {:ok, _user, :existing_identity} = Provisioning.provision(ctx.connection, claims)
    end
  end

  describe "a known identity" do
    setup ctx do
      user = user_fixture(%{email: "known@#{ctx.domain}"})
      organization_member_fixture(ctx.organization, user)
      identity = identity_fixture(user, ctx.connection, "known-subject")
      %{user: user, identity: identity}
    end

    test "decides the account by subject even when the email changed", ctx do
      claims =
        claims(ctx.domain, %{"sub" => "known-subject", "email" => "renamed@elsewhere.example"})

      long_ago = ~U[2020-01-01 00:00:00Z]
      ctx.identity |> Ecto.Changeset.change(last_login_at: long_ago) |> Repo.update!()

      assert {:ok, user, :existing_identity} = Provisioning.provision(ctx.connection, claims)
      assert user.id == ctx.user.id
      assert Repo.reload(user).email == "known@#{ctx.domain}"
      assert DateTime.after?(Repo.reload(ctx.identity).last_login_at, long_ago)
    end

    test "does not match the subject of another issuer", ctx do
      repointed = %{ctx.connection | issuer: "https://login.example.com"}

      assert {:ok, user, :provisioned} =
               Provisioning.provision(repointed, claims(ctx.domain, %{"sub" => "known-subject"}))

      refute user.id == ctx.user.id
    end

    test "is refused when the account is disabled", ctx do
      ctx.user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :user_disabled} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"sub" => "known-subject"})
               )
    end

    test "is refused once the account has become a site admin", ctx do
      {:ok, _admin} = Accounts.update_user_type(ctx.user, :admin)

      assert {:error, :site_admin} =
               Provisioning.provision(
                 ctx.connection,
                 claims(ctx.domain, %{"sub" => "known-subject"})
               )
    end

    test "a removed member rejoins only through the email gate", ctx do
      from(m in OrganizationMember, where: m.user_id == ^ctx.user.id) |> Repo.delete_all()

      refused = claims(ctx.domain, %{"sub" => "known-subject", "email_verified" => false})
      assert {:error, :email_not_verified} = Provisioning.provision(ctx.connection, refused)
      refute Organizations.member?(ctx.user, ctx.organization.id)

      accepted = claims(ctx.domain, %{"sub" => "known-subject", "email" => ctx.user.email})
      assert {:ok, _user, :existing_identity} = Provisioning.provision(ctx.connection, accepted)
      assert Organizations.member?(ctx.user, ctx.organization.id)
    end

    test "a removed member whose own email left the verified domains is not signed in", ctx do
      from(m in OrganizationMember, where: m.user_id == ^ctx.user.id) |> Repo.delete_all()
      ctx.user |> Ecto.Changeset.change(email: "known@elsewhere.example") |> Repo.update!()

      claims = claims(ctx.domain, %{"sub" => "known-subject"})
      assert {:error, :domain_not_verified} = Provisioning.provision(ctx.connection, claims)
      refute Organizations.member?(ctx.user, ctx.organization.id)
    end

    test "a removed member on a verified domain rejoins even when the claim email differs",
         ctx do
      from(m in OrganizationMember, where: m.user_id == ^ctx.user.id) |> Repo.delete_all()

      claims =
        claims(ctx.domain, %{"sub" => "known-subject", "email" => "renamed@elsewhere.example"})

      assert {:ok, user, :existing_identity} = Provisioning.provision(ctx.connection, claims)
      assert user.id == ctx.user.id
      assert Organizations.member?(ctx.user, ctx.organization.id)
    end

    test "a member SCIM deprovisioned is signed in again only once SCIM re-activates them",
         ctx do
      token = scim_deprovision(ctx.organization, ctx.user)
      claims = claims(ctx.domain, %{"sub" => "known-subject", "email" => ctx.user.email})

      assert {:error, :scim_deprovisioned} = Provisioning.provision(ctx.connection, claims)
      refute Organizations.member?(ctx.user, ctx.organization.id)

      assert {:ok, _user} = Lifecycle.reactivate(token, ctx.user)
      assert {:ok, user, :existing_identity} = Provisioning.provision(ctx.connection, claims)
      assert user.id == ctx.user.id
    end

    test "a removed member who joined another Organization is refused", ctx do
      from(m in OrganizationMember, where: m.user_id == ^ctx.user.id) |> Repo.delete_all()
      organization_fixture() |> organization_member_fixture(ctx.user)

      claims = claims(ctx.domain, %{"sub" => "known-subject", "email" => ctx.user.email})
      assert {:error, :membership_conflict} = Provisioning.provision(ctx.connection, claims)
    end
  end

  describe "provision_scim/2 (W2247)" do
    defp scim_email(domain), do: "scim#{System.unique_integer([:positive])}@#{domain}"

    test "creates a confirmed account managed by the Organization, with a member role", ctx do
      email = scim_email(ctx.domain)

      assert {:ok, user, :provisioned} =
               Provisioning.provision_scim(ctx.organization.id, %{email: email, name: "Pat"})

      assert user.confirmed_at
      assert is_nil(user.hashed_password)
      assert user.managed_by_organization_id == ctx.organization.id

      assert %OrganizationMember{role: :member} =
               Repo.get_by(OrganizationMember, user_id: user.id)

      assert %Workspace{personal: true} = Kanban.Workspaces.get_personal_workspace(user)
      assert identities(user) == []
    end

    test "links an existing account without managing it and keeps an org-admin's role", ctx do
      member = user_fixture(%{email: scim_email(ctx.domain)})

      assert {:ok, linked, :linked} =
               Provisioning.provision_scim(ctx.organization.id, %{email: member.email, name: nil})

      assert linked.id == member.id
      assert is_nil(Repo.reload(member).managed_by_organization_id)
      assert Organizations.member?(member, ctx.organization.id)

      org_admin = user_fixture(%{email: scim_email(ctx.domain)})
      organization_member_fixture(ctx.organization, org_admin, :org_admin)

      assert {:ok, _user, :linked} =
               Provisioning.provision_scim(ctx.organization.id, %{
                 email: org_admin.email,
                 name: nil
               })

      assert Organizations.org_admin?(org_admin, ctx.organization.id)
    end

    test "refuses an unverified domain, a disabled account and another Organization's member",
         ctx do
      assert Provisioning.provision_scim(ctx.organization.id, %{
               email: "a@unverified.example",
               name: nil
             }) ==
               {:error, :domain_not_verified}

      disabled = user_fixture(%{email: scim_email(ctx.domain)})
      {:ok, _} = disabled |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update()

      assert Provisioning.provision_scim(ctx.organization.id, %{email: disabled.email, name: nil}) ==
               {:error, :user_disabled}

      elsewhere = user_fixture(%{email: scim_email(ctx.domain)})
      organization_member_fixture(organization_fixture(), elsewhere)

      assert Provisioning.provision_scim(ctx.organization.id, %{email: elsewhere.email, name: nil}) ==
               {:error, :membership_conflict}

      refute Organizations.member?(elsewhere, ctx.organization.id)
    end

    test "refuses a site admin and writes nothing", ctx do
      admin = admin_fixture(%{email: scim_email(ctx.domain)})

      assert Provisioning.provision_scim(ctx.organization.id, %{email: admin.email, name: nil}) ==
               {:error, :site_admin}

      refute Organizations.member?(admin, ctx.organization.id)
    end
  end
end
