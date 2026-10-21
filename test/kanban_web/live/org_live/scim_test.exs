defmodule KanbanWeb.OrgLive.SCIMTest do
  @moduledoc "The org-admin SCIM provisioning page at `/org/scim` (W2247)."
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures

  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM
  alias Kanban.SCIM.ScimToken

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

  test "the org console links to the page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/org")
    assert lv |> element("#org-scim-link") |> render() =~ ~s(href="/org/scim")
  end

  test "shows the base URL and the empty token list", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/org/scim")
    assert lv |> element("#scim-base-url") |> render() =~ "/scim/v2"
    assert has_element?(lv, "#no-scim-tokens")
    refute has_element?(lv, "#scim-token-reveal")
  end

  test "creating a token shows its plain text once", %{conn: conn, org: org} do
    {:ok, lv, _html} = live(conn, ~p"/org/scim")

    lv |> form("#scim-token-form", token: %{name: ""}) |> render_change()
    assert render(lv) =~ "can&#39;t be blank"

    lv |> form("#scim-token-form", token: %{name: "Okta"}) |> render_submit()

    assert [token] = SCIM.list_tokens(org.id)
    plaintext = lv |> element("#scim-token-value") |> render() |> extract_token()
    assert Repo.get!(ScimToken, token.id).token_hash == ScimToken.hash(plaintext)
    assert has_element?(lv, "#scim-token-#{token.id}")

    render_click(lv, "dismiss_token", %{})
    refute has_element?(lv, "#scim-token-reveal")

    {:ok, _lv, html} = live(conn, ~p"/org/scim")
    refute html =~ plaintext
  end

  test "revoking a token marks it revoked", %{conn: conn, org: org, org_admin: org_admin} do
    {token, _plaintext} = scim_token_fixture(org, %{created_by: org_admin})
    {:ok, lv, _html} = live(conn, ~p"/org/scim")

    lv |> element("#revoke-scim-token-#{token.id}") |> render_click()

    assert Repo.get!(ScimToken, token.id).revoked_at
    refute has_element?(lv, "#revoke-scim-token-#{token.id}")
    assert render(lv) =~ "Token revoked."
  end

  test "another Organization's token cannot be revoked from here", %{conn: conn} do
    {other, _plaintext} = scim_token_fixture(organization_fixture())
    {:ok, lv, html} = live(conn, ~p"/org/scim")
    refute html =~ "scim-token-#{other.id}"

    render_click(lv, "revoke_token", %{"id" => "#{other.id}"})
    refute Repo.get!(ScimToken, other.id).revoked_at
  end

  test "a member is refused and the refusal is audited", %{conn: conn, org: org} do
    member = user_fixture()
    organization_member_fixture(org, member)

    assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
             live(log_in_user(conn, member), ~p"/org/scim")

    assert flash["error"] == @refusal
    assert [_event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
  end

  test "an org-admin demoted while the page is open is refused on every event",
       %{conn: conn, org: org, org_admin: org_admin} do
    {token, _plaintext} = scim_token_fixture(org, %{created_by: org_admin})

    events = [
      fn lv -> lv |> form("#scim-token-form", token: %{name: "x"}) |> render_change() end,
      fn lv -> lv |> form("#scim-token-form", token: %{name: "x"}) |> render_submit() end,
      fn lv -> render_click(lv, "revoke_token", %{"id" => "#{token.id}"}) end
    ]

    for event <- events do
      from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
      |> Repo.update_all(set: [role: :org_admin])

      {:ok, lv, _html} = live(conn, ~p"/org/scim")
      demote(org_admin)

      assert {:error, {:redirect, %{to: "/boards"}}} = event.(lv)
    end

    assert [%{revoked_at: nil}] = SCIM.list_tokens(org.id)

    assert length(AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)) ==
             3
  end

  defp extract_token(html) do
    [token] = Regex.run(~r/stride_scim_[A-Za-z0-9_-]+/, html)
    token
  end
end
