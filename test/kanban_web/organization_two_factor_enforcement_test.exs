defmodule KanbanWeb.OrganizationTwoFactorEnforcementTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.ApiTokens
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo
  alias Kanban.TwoFactorHelpers
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  @settings "/users/settings?section=two_factor"
  @day 24 * 60 * 60

  setup do
    org = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(org, admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(org, member)
    {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

    %{org: org, admin: admin, member: member}
  end

  # Moves the policy and every membership 30 days into the past, so the 7-day
  # grace period of everyone in the Organization has ended.
  defp make_overdue(%{org: org}) do
    past = :second |> DateTime.utc_now() |> DateTime.add(-30 * @day, :second)

    from(p in SecurityPolicy, where: p.organization_id == ^org.id)
    |> Repo.update_all(set: [two_factor_enforced_at: past])

    from(m in OrganizationMember, where: m.organization_id == ^org.id)
    |> Repo.update_all(set: [inserted_at: past])

    :ok
  end

  describe "within the grace period" do
    test "a member sees the banner with their deadline and can keep working",
         %{conn: conn, member: member} do
      {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/boards")

      assert has_element?(lv, "#organization-two-factor-banner")
      assert has_element?(lv, "#organization-two-factor-banner-deadline")
      refute has_element?(lv, "#organization-two-factor-banner-overdue")
      assert has_element?(lv, ~s(#organization-two-factor-banner-setup[href="#{@settings}"]))

      {:ok, _lv, _html} = conn |> log_in_user(member) |> live(~p"/my-work")
    end

    test "the banner is not shown to an enrolled member or to someone outside the Organization",
         %{conn: conn, member: member} do
      TwoFactorHelpers.enroll(member)
      {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/boards")
      refute has_element?(lv, "#organization-two-factor-banner")

      {:ok, lv, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/boards")
      refute has_element?(lv, "#organization-two-factor-banner")
    end
  end

  describe "after the grace deadline" do
    setup :make_overdue

    test "a LiveView page redirects to the two-factor section of the settings page",
         %{conn: conn, member: member} do
      assert {:error, {:redirect, %{to: @settings, flash: flash}}} =
               conn |> log_in_user(member) |> live(~p"/boards")

      assert flash["error"] =~ "Your Organization requires two-factor authentication"
    end

    test "a controller page redirects too", %{conn: conn, member: member} do
      conn = conn |> log_in_user(member) |> get(~p"/locked/sso")
      assert redirected_to(conn) == @settings
    end

    test "the org-admin who enabled it is held to it as well", %{conn: conn, admin: admin} do
      assert {:error, {:redirect, %{to: @settings}}} =
               conn |> log_in_user(admin) |> live(~p"/org")
    end

    test "a site admin who is a member is redirected from the admin pages",
         %{conn: conn, org: org} do
      site_admin = admin_fixture()
      organization_member_fixture(org, site_admin)
      make_overdue(%{org: org})

      assert {:error, {:redirect, %{to: @settings}}} =
               conn |> log_in_user(site_admin) |> live(~p"/admin/users")
    end

    test "the settings page still opens, with the overdue banner, so there is no redirect loop",
         %{conn: conn, member: member} do
      {:ok, lv, _html} = conn |> log_in_user(member) |> live(@settings)

      assert has_element?(lv, "#organization-two-factor-banner-overdue")
      assert has_element?(lv, "#two-factor-begin")
    end

    test "log-out still works", %{conn: conn, member: member} do
      conn = conn |> log_in_user(member) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
    end

    test "enrolling ends the redirect on the next request", %{conn: conn, member: member} do
      TwoFactorHelpers.enroll(member)
      {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/boards")
      refute has_element?(lv, "#organization-two-factor-banner")
    end

    test "turning the policy off ends the redirect on the next request",
         %{conn: conn, admin: admin, member: member} do
      TwoFactorHelpers.enroll(admin)
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "false"})
      {:ok, _lv, _html} = conn |> log_in_user(member) |> live(~p"/boards")
    end

    test "leaving the Organization ends the redirect on the next request",
         %{conn: conn, member: member} do
      from(m in OrganizationMember, where: m.user_id == ^member.id) |> Repo.delete_all()
      {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/boards")
      refute has_element?(lv, "#organization-two-factor-banner")
    end

    test "a session marked as signed in through SSO is not redirected",
         %{conn: conn, org: org, member: member} do
      conn =
        conn
        |> log_in_user(member)
        |> Plug.Conn.put_session(OrganizationTwoFactorGate.sso_session_key(), org.id)

      {:ok, lv, _html} = live(conn, ~p"/boards")
      refute has_element?(lv, "#organization-two-factor-banner")
    end

    test "a session signed in through another Organization's SSO is still redirected",
         %{conn: conn, member: member} do
      # The member signed in through their previous Organization's identity
      # provider, then left it and joined this one in the same session.
      conn =
        conn
        |> log_in_user(member)
        |> Plug.Conn.put_session(
          OrganizationTwoFactorGate.sso_session_key(),
          organization_fixture().id
        )

      assert redirected_to(get(conn, ~p"/boards")) == @settings
      assert {:error, {:redirect, %{to: @settings}}} = live(conn, ~p"/my-work")
    end

    test "an SSO marker in the request params is ignored", %{conn: conn, member: member} do
      conn = conn |> log_in_user(member) |> get(~p"/locked/sso?sso_authenticated=true")
      assert redirected_to(conn) == @settings
    end

    test "an API-token request from an overdue member still succeeds",
         %{conn: conn, member: member} do
      board = ai_optimized_board_fixture(member)
      {:ok, {_token, plain}} = ApiTokens.create_api_token(member, board, %{name: "Agent"})

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{plain}")
        |> get(~p"/api/boards")

      assert %{"data" => [_ | _]} = json_response(conn, 200)
    end
  end
end
