defmodule KanbanWeb.OrgLive.SecurityTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.FeatureFlags
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

    test "the 2FA enforcement time renders local and localised", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      submit(lv, %{"require_two_factor" => "true"})

      {1, _} =
        from(p in SecurityPolicy, where: p.organization_id == ^org.id)
        |> Repo.update_all(set: [two_factor_enforced_at: ~U[2026-10-01 09:00:00Z]])

      {:ok, lv, _html} =
        conn
        |> Plug.Test.init_test_session(%{"timezone" => "America/Toronto", "locale" => "es"})
        |> live(~p"/org/security")

      assert has_element?(lv, "#two-factor-enforced-at", "1 de octubre de 2026, 05:00")
      refute lv |> element("#two-factor-enforced-at") |> render() =~ "UTC"
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

    test "an org admin toggles the policy and an audit row is written",
         %{conn: conn, org: org, org_admin: org_admin} do
      :ok = FeatureFlags.enable_for_user(:mobile_app_preview, org_admin)
      {:ok, lv, html} = live(conn, ~p"/org/security")

      assert html =~ "Notification privacy"

      assert has_element?(
               lv,
               ~s(#notification-privacy-policy input[type="checkbox"][name="security_policy[hide_titles_in_notifications]"])
             )

      refute has_element?(
               lv,
               ~s(input[name="security_policy[hide_titles_in_notifications]"][checked])
             )

      assert submit(lv, %{"hide_titles_in_notifications" => "true"}) =~ "Security policy saved."

      assert SecurityPolicies.policy_for_organization(org.id).hide_titles_in_notifications
      assert SecurityPolicies.hide_titles?(org_admin)

      assert has_element?(
               lv,
               ~s(input[name="security_policy[hide_titles_in_notifications]"][checked])
             )

      assert [event] =
               AuditLog.list_events(
                 action: :organization_policy_updated,
                 actor_user_id: org_admin.id
               )

      assert event.organization_id == org.id
      assert event.metadata["old_values"] == %{"hide_titles_in_notifications" => false}
      assert event.metadata["new_values"] == %{"hide_titles_in_notifications" => true}
    end

    test "a member can't change it", %{conn: conn, org: org} do
      member = user_fixture()
      organization_member_fixture(org, member)

      assert {:error, {:redirect, %{to: "/boards"}}} =
               live(log_in_user(conn, member), ~p"/org/security")

      assert {:error, :unauthorized} =
               SecurityPolicies.update_policy(member, %{"hide_titles_in_notifications" => "true"})

      assert SecurityPolicies.policy_for_organization(org.id).id == nil
      refute SecurityPolicies.hide_titles?(member)
      assert AuditLog.list_events(action: :organization_policy_updated) == []
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

    # D5: saving the form unchanged shows the flash and writes nothing.
    test "a no-op save by another admin shows the saved flash and keeps the last editor",
         %{conn: conn, org: org, org_admin: org_admin} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      submit(lv, %{"require_two_factor" => "true", "two_factor_grace_days" => "14"})
      saved = SecurityPolicies.policy_for_organization(org.id)

      stamped = ~U[2026-10-01 09:00:00Z]

      {1, _} =
        from(p in SecurityPolicy, where: p.id == ^saved.id)
        |> Repo.update_all(set: [updated_at: stamped])

      other_admin = user_fixture()
      organization_member_fixture(org, other_admin, :org_admin)
      :ok = FeatureFlags.enable_for_user(:mobile_app_preview, other_admin)
      {:ok, other_lv, _html} = live(log_in_user(build_conn(), other_admin), ~p"/org/security")

      html =
        submit(other_lv, %{
          "require_two_factor" => "true",
          "two_factor_grace_days" => "14",
          "audit_retention_days" => "",
          "hide_titles_in_notifications" => "false"
        })

      assert html =~ "Security policy saved."
      reloaded = Repo.get!(SecurityPolicy, saved.id)
      assert reloaded.updated_by_id == org_admin.id
      assert reloaded.updated_at == stamped

      assert [_one] = AuditLog.list_events(action: :organization_policy_updated)

      assert AuditLog.list_events(
               action: :organization_policy_updated,
               actor_user_id: other_admin.id
             ) == []
    end

    test "an empty retention keeps audit events forever", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      submit(lv, %{"audit_retention_days" => "400"})
      submit(lv, %{"audit_retention_days" => ""})

      assert SecurityPolicies.policy_for_organization(org.id).audit_retention_days == nil
    end
  end

  # D441: a value that is not a string failed the cast but stayed in the
  # changeset params, so the re-rendered input raised and crashed the view.
  describe "malformed params" do
    test "a map- or list-valued field does not crash the policy form", %{
      conn: conn,
      org: org,
      org_admin: org_admin
    } do
      # Stored as true, so a checkbox value that was blanked instead of
      # dropped shows: Ecto casts a blank to the schema default, false.
      {:ok, _policy} =
        SecurityPolicies.update_policy(org_admin, %{"hide_titles_in_notifications" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/org/security")

      for event <- ["validate", "save"],
          field <- [
            "require_two_factor",
            "two_factor_grace_days",
            "audit_retention_days",
            "hide_titles_in_notifications"
          ],
          value <- [%{"a" => "1"}, [%{"a" => "1"}], 42] do
        html = render_hook(lv, event, %{"security_policy" => %{field => value}})

        assert Process.alive?(lv.pid)
        assert html =~ "security-policy-form"
      end

      policy = SecurityPolicies.policy_for_organization(org.id)
      refute policy.require_two_factor
      # the crafted values were dropped, so the stored true stands
      assert policy.hide_titles_in_notifications
    end

    test "a crafted hide_titles_in_notifications value is dropped, not saved or shown",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")

      html =
        render_hook(lv, "save", %{
          "security_policy" => %{"hide_titles_in_notifications" => "maybe"}
        })

      assert html =~ "Security policy saved."
      refute html =~ "is invalid"
      refute SecurityPolicies.policy_for_organization(org.id).hide_titles_in_notifications
    end

    test "a missing or non-map security_policy param is ignored", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")

      for event <- ["validate", "save"],
          payload <- [%{}, %{"security_policy" => "x"}, %{"security_policy" => [1]}] do
        assert render_hook(lv, event, payload) =~ "security-policy-form"
        assert Process.alive?(lv.pid)
      end

      assert SecurityPolicies.policy_for_organization(org.id).id == nil
    end

    test "a demoted admin sending malformed params is refused and audited",
         %{conn: conn, org_admin: org_admin} do
      events =
        for event <- ["validate", "save"],
            payload <- [
              %{"security_policy" => "x"},
              %{"security_policy" => %{"two_factor_grace_days" => %{"a" => "1"}}}
            ],
            do: {event, payload}

      for {event, payload} <- events do
        from(m in OrganizationMember, where: m.user_id == ^org_admin.id)
        |> Repo.update_all(set: [role: :org_admin])

        {:ok, lv, _html} = live(conn, ~p"/org/security")
        demote(org_admin)

        assert {:error, {:redirect, %{to: "/boards"}}} = render_hook(lv, event, payload)
      end

      assert length(AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)) ==
               length(events)
    end
  end

  describe "when the hide-titles checkbox shows (W2911)" do
    @hide_titles_input ~s(input[name="security_policy[hide_titles_in_notifications]"])

    defp hide_titles_on!(org_admin) do
      {:ok, _policy} =
        SecurityPolicies.update_policy(org_admin, %{"hide_titles_in_notifications" => "true"})
    end

    test "the hide-titles checkbox is hidden for an unflagged org admin while the policy is off",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/org/security")

      assert has_element?(lv, "#security-policy-form")
      refute has_element?(lv, "#notification-privacy-policy")
      # the core checkbox's hidden "false" input goes with it
      refute has_element?(lv, @hide_titles_input)
      refute html =~ "Notification privacy"
    end

    test "it shows for a flagged org admin, and for anyone while the policy is already on",
         %{conn: conn, org_admin: org_admin} do
      :ok = FeatureFlags.enable_for_user(:mobile_app_preview, org_admin)
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      assert has_element?(lv, ~s(#notification-privacy-policy input[type="checkbox"]))
      refute has_element?(lv, "#{@hide_titles_input}[checked]")

      # the flag turned off while the policy is on keeps the checkbox visible
      hide_titles_on!(org_admin)
      :ok = FeatureFlags.disable_for_user(:mobile_app_preview, org_admin)
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      assert has_element?(lv, ~s(#notification-privacy-policy #{@hide_titles_input}[checked]))
    end

    test "an unflagged org admin can turn an active policy off, and the checkbox then goes",
         %{conn: conn, org: org, org_admin: org_admin} do
      hide_titles_on!(org_admin)
      {:ok, lv, _html} = live(conn, ~p"/org/security")

      assert submit(lv, %{"hide_titles_in_notifications" => "false"}) =~ "Security policy saved."

      refute SecurityPolicies.policy_for_organization(org.id).hide_titles_in_notifications
      refute has_element?(lv, "#notification-privacy-policy")
    end

    test "a crafted hide-titles value sent while the checkbox is hidden is refused",
         %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      refute has_element?(lv, @hide_titles_input)

      for event <- ["validate", "save"] do
        render_hook(lv, event, %{
          "security_policy" => %{
            "require_two_factor" => "true",
            "hide_titles_in_notifications" => "true"
          }
        })
      end

      policy = SecurityPolicies.policy_for_organization(org.id)
      # the visible field still saved; the hidden one did not
      assert policy.require_two_factor
      refute policy.hide_titles_in_notifications
      refute has_element?(lv, "#notification-privacy-policy")
    end

    test "saving the form while the checkbox is hidden leaves hide_titles_in_notifications unchanged",
         %{conn: conn, org: org, org_admin: org_admin} do
      {:ok, lv, _html} = live(conn, ~p"/org/security")
      refute has_element?(lv, @hide_titles_input)

      # The policy goes on behind the open page, which still has no checkbox
      # and so sends no value for it.
      hide_titles_on!(org_admin)

      lv
      |> form("#security-policy-form",
        security_policy: %{"require_two_factor" => "true", "two_factor_grace_days" => "14"}
      )
      |> render_change()

      html = submit(lv, %{"require_two_factor" => "true", "two_factor_grace_days" => "14"})
      assert html =~ "Security policy saved."

      policy = SecurityPolicies.policy_for_organization(org.id)
      assert policy.require_two_factor
      assert policy.hide_titles_in_notifications
      assert SecurityPolicies.hide_titles?(org_admin)
      assert has_element?(lv, "#{@hide_titles_input}[checked]")
    end
  end
end
