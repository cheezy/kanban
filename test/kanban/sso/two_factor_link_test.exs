defmodule Kanban.SSO.TwoFactorLinkTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.TwoFactorLink

  doctest Kanban.SSO.TwoFactorLink

  setup do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization).domain
    connection = oidc_connection_fixture(organization)
    user = user_fixture(%{email: "pat@#{domain}"})
    link = TwoFactorLink.link(connection, "sub-#{System.unique_integer([:positive])}")
    %{organization: organization, connection: connection, user: user, link: link}
  end

  test "links the account, signs it in and records the login with its protocol", ctx do
    assert {:ok, user} = SSO.complete_two_factor_link(ctx.user, ctx.link, ip: {127, 0, 0, 1})

    assert user.id == ctx.user.id
    assert Organizations.member?(user, ctx.organization.id)
    assert [_linked] = AuditLog.list_events(action: "sso_account_linked")
    assert [event] = AuditLog.list_events(action: "sso_login")
    assert event.metadata["protocol"] == "oidc"
    assert event.organization_id == ctx.organization.id
  end

  test "a connection disabled since the sign-in is refused and audited", ctx do
    ctx.connection |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    assert {:error, :connection_unavailable} =
             TwoFactorLink.complete(ctx.user, ctx.link, ip: {127, 0, 0, 1})

    refute Organizations.member?(ctx.user, ctx.organization.id)
    assert [event] = AuditLog.list_events(action: "sso_login_refused")
    assert event.metadata["reason"] == "connection_unavailable"
  end

  test "a refused link is audited with its reason and the connection", ctx do
    other = organization_fixture()
    organization_member_fixture(other, ctx.user)

    assert {:error, :membership_conflict} = TwoFactorLink.complete(ctx.user, ctx.link, [])

    assert [event] = AuditLog.list_events(action: "sso_login_refused")
    assert event.metadata["reason"] == "membership_conflict"
    assert event.metadata["protocol"] == "oidc"
    assert event.organization_id == ctx.organization.id
    assert AuditLog.list_events(action: "sso_login") == []
  end
end
