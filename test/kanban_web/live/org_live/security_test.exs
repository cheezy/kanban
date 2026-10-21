defmodule KanbanWeb.OrgLive.SecurityTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo

  @refusal "You must be an org-admin of an Organization to access this page."

  setup %{conn: conn} do
    org = organization_fixture(%{name: "Acme Widgets"})
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), org: org, org_admin: org_admin}
  end

  defp submit(lv, params) do
    lv |> form("#security-policy-form", security_policy: params) |> render_submit()
  end

  describe "access control" do
    test "a member is refused on the server and the refusal is audited", %{conn: conn, org: org} do
      member = user_fixture()
      organization_member_fixture(org, member)

      assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
               live(log_in_user(conn, member), ~p"/org/security")

      assert flash["error"] == @refusal
      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)
      assert event.metadata["gate"] == "require_org_admin"
    end

    test "a user outside the Organization and a site admin are refused", %{conn: conn} do
      for user <- [user_fixture(), admin_fixture()] do
        assert {:error, {:redirect, %{to: "/boards"}}} =
                 live(log_in_user(conn, user), ~p"/org/security")
      end
    end

    test "a visitor is sent to log in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/org/security")
    end

    test "an org-admin demoted while the page is open is refused on validate",
         %{conn: conn, org_admin: org_admin} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      demote(org_admin)

      assert {:error, {:redirect, %{to: "/boards"}}} =
               lv
               |> form("#security-policy-form",
                 security_policy: %{"two_factor_grace_days" => "3"}
               )
               |> render_change()
    end

    test "an org-admin demoted while the page is open is refused on save and nothing is written",
         %{conn: conn, org: org, org_admin: org_admin} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      demote(org_admin)

      assert {:error, {:redirect, %{to: "/boards"}}} =
               submit(lv, %{"require_two_factor" => "true"})

      assert SecurityPolicies.policy_for_organization(org.id).id == nil

      assert [event] =
               AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)

      assert event.metadata["gate"] == "require_org_admin"
    end
  end

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  describe "the policy form" do
    test "shows the defaults and the console links to it", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/org/security")

      assert html =~ "Security policy for Acme Widgets"
      assert html =~ "Members who sign in through single sign-on are not affected."
      assert has_element?(lv, ~s(input[name="security_policy[two_factor_grace_days]"][value="7"]))
      refute has_element?(lv, "#two-factor-enforced-at")

      {:ok, console, _html} = live(conn, ~p"/org")
      assert has_element?(console, ~s(#org-security-link[href="/org/security"]))
    end

    test "an org-admin saves require-2FA, grace days and retention, and it is audited",
         %{conn: conn, org: org, org_admin: org_admin} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")

      html =
        submit(lv, %{
          "require_two_factor" => "true",
          "two_factor_grace_days" => "14",
          "audit_retention_days" => "365"
        })

      assert html =~ "Security policy saved."
      assert has_element?(lv, "#two-factor-enforced-at")

      policy = SecurityPolicies.policy_for_organization(org.id)
      assert %SecurityPolicy{require_two_factor: true, two_factor_grace_days: 14} = policy
      assert policy.audit_retention_days == 365

      assert [event] =
               AuditLog.list_events(
                 action: :organization_policy_updated,
                 actor_user_id: org_admin.id
               )

      assert event.organization_id == org.id
    end

    test "out-of-range values show errors and save nothing", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")

      html =
        lv
        |> form("#security-policy-form",
          security_policy: %{"two_factor_grace_days" => "31", "audit_retention_days" => "30"}
        )
        |> render_change()

      assert html =~ "must be less than or equal to 30"
      assert html =~ "must be greater than or equal to 90"

      html = submit(lv, %{"two_factor_grace_days" => "0", "audit_retention_days" => "4000"})
      assert html =~ "must be greater than or equal to 1"
      assert html =~ "must be less than or equal to 3650"
      assert SecurityPolicies.policy_for_organization(org.id).id == nil
    end

    test "an empty retention keeps audit events forever", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      submit(lv, %{"audit_retention_days" => "400"})
      submit(lv, %{"audit_retention_days" => ""})

      assert SecurityPolicies.policy_for_organization(org.id).audit_retention_days == nil
    end
  end
end
