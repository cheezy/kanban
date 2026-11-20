defmodule Kanban.Organizations.SecurityPolicyTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.TwoFactorHelpers

  @now ~U[2026-10-21 12:00:00Z]
  @day 24 * 60 * 60

  defp changeset(attrs, policy \\ %SecurityPolicy{organization_id: 1}),
    do: SecurityPolicy.changeset(policy, attrs, @now)

  defp org_with_admin do
    org = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(org, admin, :org_admin)
    {org, admin}
  end

  defp backdate_membership(user, at) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [inserted_at: at])
  end

  defp policy_events do
    from(e in AuditEvent, where: e.action == "organization_policy_updated")
    |> Repo.all()
  end

  describe "changeset/3" do
    test "accepts values inside the ranges and treats a blank retention as keep forever" do
      cs = changeset(%{"two_factor_grace_days" => "30", "audit_retention_days" => "90"})
      assert cs.valid?
      assert get_change(cs, :two_factor_grace_days) == 30

      cs = changeset(%{"two_factor_grace_days" => "1", "audit_retention_days" => "3650"})
      assert cs.valid?

      cs = changeset(%{"audit_retention_days" => ""}, %SecurityPolicy{audit_retention_days: 365})
      assert cs.valid?
      assert get_field(cs, :audit_retention_days) == nil
    end

    test "rejects retention below 90 or above 3650 days with translated messages" do
      cs = changeset(%{"audit_retention_days" => "89"})
      refute cs.valid?
      assert "must be greater than or equal to 90" in errors_on(cs).audit_retention_days

      cs = changeset(%{"audit_retention_days" => "3651"})
      assert "must be less than or equal to 3650" in errors_on(cs).audit_retention_days

      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        [message] =
          changeset(%{"audit_retention_days" => "89"}).errors
          |> Keyword.get_values(:audit_retention_days)
          |> Enum.map(&KanbanWeb.CoreComponents.translate_error/1)

        refute message == "must be greater than or equal to 90"
      end)
    end

    test "rejects grace days outside 1 to 30" do
      assert "must be greater than or equal to 1" in errors_on(
               changeset(%{"two_factor_grace_days" => "0"})
             ).two_factor_grace_days

      assert "must be less than or equal to 30" in errors_on(
               changeset(%{"two_factor_grace_days" => "31"})
             ).two_factor_grace_days
    end

    test "rejects non-integers" do
      for value <- ["abc", "7.5"] do
        assert "is invalid" in errors_on(changeset(%{"two_factor_grace_days" => value})).two_factor_grace_days

        assert "is invalid" in errors_on(changeset(%{"audit_retention_days" => value})).audit_retention_days
      end
    end

    test "casts hide_titles_in_notifications, and a blank one is the default off" do
      cs = changeset(%{"hide_titles_in_notifications" => "true"})
      assert cs.valid?
      assert get_change(cs, :hide_titles_in_notifications) == true

      cs =
        changeset(%{"hide_titles_in_notifications" => ""}, %SecurityPolicy{
          hide_titles_in_notifications: true
        })

      assert cs.valid?
      assert get_field(cs, :hide_titles_in_notifications) == false

      refute changeset(%{"hide_titles_in_notifications" => "maybe"}).valid?

      assert :hide_titles_in_notifications in SecurityPolicy.editable_fields()
    end

    test "turning require on stamps now, off clears it, on again restamps" do
      on = changeset(%{"require_two_factor" => "true"})
      assert get_change(on, :two_factor_enforced_at) == @now

      enabled = %SecurityPolicy{
        require_two_factor: true,
        two_factor_enforced_at: ~U[2026-01-01 00:00:00Z]
      }

      off = changeset(%{"require_two_factor" => "false"}, enabled)
      assert get_field(off, :two_factor_enforced_at) == nil

      unchanged = changeset(%{"two_factor_grace_days" => "14"}, enabled)
      assert get_field(unchanged, :two_factor_enforced_at) == ~U[2026-01-01 00:00:00Z]
    end

    test "shortening the grace period while required restamps enforced_at" do
      enabled = %SecurityPolicy{
        require_two_factor: true,
        two_factor_grace_days: 14,
        two_factor_enforced_at: ~U[2026-01-01 00:00:00Z]
      }

      assert get_field(
               changeset(%{"two_factor_grace_days" => "3"}, enabled),
               :two_factor_enforced_at
             ) ==
               @now
    end

    test "never casts organization_id, updated_by_id or enforced_at" do
      cs =
        changeset(%{
          "organization_id" => "999",
          "updated_by_id" => "999",
          "two_factor_enforced_at" => "2020-01-01T00:00:00Z"
        })

      assert get_field(cs, :organization_id) == 1
      assert get_field(cs, :updated_by_id) == nil
      assert get_field(cs, :two_factor_enforced_at) == nil
    end
  end

  describe "policy_for_organization/1" do
    test "returns the defaults when the Organization has no policy" do
      org = organization_fixture()
      policy = SecurityPolicies.policy_for_organization(org.id)

      assert %SecurityPolicy{id: nil, organization_id: id} = policy
      assert id == org.id
      refute policy.require_two_factor
      assert policy.two_factor_grace_days == 7
      assert policy.audit_retention_days == nil
      refute policy.hide_titles_in_notifications
    end
  end

  describe "update_policy/2" do
    test "an org-admin saves their own Organization's policy and the change is audited" do
      {org, admin} = org_with_admin()

      assert {:ok, policy} =
               SecurityPolicies.update_policy(admin, %{
                 "require_two_factor" => "true",
                 "audit_retention_days" => "365",
                 "organization_id" => "#{org.id + 1000}"
               })

      assert policy.organization_id == org.id
      assert policy.require_two_factor
      assert policy.two_factor_enforced_at
      assert policy.updated_by_id == admin.id

      assert [event] = policy_events()
      assert event.actor_user_id == admin.id
      assert event.organization_id == org.id

      assert event.metadata["old_values"] == %{
               "require_two_factor" => false,
               "audit_retention_days" => nil
             }

      assert event.metadata["new_values"] == %{
               "require_two_factor" => true,
               "audit_retention_days" => 365
             }
    end

    test "turning hide_titles_in_notifications on and off is audited" do
      {org, admin} = org_with_admin()

      assert {:ok, policy} =
               SecurityPolicies.update_policy(admin, %{"hide_titles_in_notifications" => "true"})

      assert policy.hide_titles_in_notifications

      {:ok, _} =
        SecurityPolicies.update_policy(admin, %{"hide_titles_in_notifications" => "false"})

      assert [on, off] = Enum.sort_by(policy_events(), & &1.id)
      assert on.organization_id == org.id
      assert on.metadata["old_values"] == %{"hide_titles_in_notifications" => false}
      assert on.metadata["new_values"] == %{"hide_titles_in_notifications" => true}
      assert off.metadata["old_values"] == %{"hide_titles_in_notifications" => true}
      assert off.metadata["new_values"] == %{"hide_titles_in_notifications" => false}
    end

    test "a save that changes nothing records no audit event" do
      {_org, admin} = org_with_admin()
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"two_factor_grace_days" => "10"})
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"two_factor_grace_days" => "10"})

      assert length(policy_events()) == 1
    end

    # D5: a save with no field different writes nothing at all.
    test "a no-op save by another admin leaves the editor, the time, the audit log and telemetry alone" do
      {org, admin} = org_with_admin()
      other_admin = user_fixture()
      organization_member_fixture(org, other_admin, :org_admin)

      {:ok, saved} =
        SecurityPolicies.update_policy(admin, %{
          "require_two_factor" => "true",
          "two_factor_grace_days" => "10"
        })

      stamped = ~U[2026-10-01 09:00:00Z]

      {1, _} =
        from(p in SecurityPolicy, where: p.id == ^saved.id)
        |> Repo.update_all(set: [updated_at: stamped])

      Kanban.TelemetryHelpers.attach_telemetry([:kanban, :audit, :organization_policy_updated])

      assert {:ok, returned} =
               SecurityPolicies.update_policy(other_admin, %{
                 "require_two_factor" => "true",
                 "two_factor_grace_days" => "10",
                 "audit_retention_days" => "",
                 "hide_titles_in_notifications" => "false"
               })

      assert returned.id == saved.id
      reloaded = Repo.get!(SecurityPolicy, saved.id)
      assert reloaded.updated_by_id == admin.id
      assert reloaded.updated_at == stamped
      assert reloaded.two_factor_enforced_at == saved.two_factor_enforced_at
      assert length(policy_events()) == 1
      refute_received {:telemetry_event, [:kanban, :audit, :organization_policy_updated], _, _}
    end

    test "a real change by another admin is written, attributed and audited as before" do
      {org, admin} = org_with_admin()
      other_admin = user_fixture()
      organization_member_fixture(org, other_admin, :org_admin)
      {:ok, saved} = SecurityPolicies.update_policy(admin, %{"two_factor_grace_days" => "10"})

      Kanban.TelemetryHelpers.attach_telemetry([:kanban, :audit, :organization_policy_updated])

      assert {:ok, changed} =
               SecurityPolicies.update_policy(other_admin, %{
                 "two_factor_grace_days" => "12",
                 "hide_titles_in_notifications" => "false"
               })

      assert changed.updated_by_id == other_admin.id
      assert Repo.get!(SecurityPolicy, saved.id).two_factor_grace_days == 12
      assert [_first, second] = Enum.sort_by(policy_events(), & &1.id)
      assert second.metadata["new_values"] == %{"two_factor_grace_days" => 12}
      assert_received {:telemetry_event, [:kanban, :audit, :organization_policy_updated], _, _}
    end

    test "a no-op save for an Organization with no policy row inserts none" do
      {org, admin} = org_with_admin()

      assert {:ok, %SecurityPolicy{id: nil, organization_id: org_id}} =
               SecurityPolicies.update_policy(admin, %{
                 "require_two_factor" => "false",
                 "two_factor_grace_days" => "7",
                 "audit_retention_days" => "",
                 "hide_titles_in_notifications" => "false"
               })

      assert org_id == org.id
      assert Repo.aggregate(SecurityPolicy, :count) == 0
      assert policy_events() == []
    end

    test "a member, an outsider and a site admin who is not an org-admin are refused and nothing is written" do
      {org, _admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      outsider = user_fixture()
      site_admin = admin_fixture()

      for user <- [member, outsider, site_admin] do
        assert SecurityPolicies.update_policy(user, %{"require_two_factor" => "true"}) ==
                 {:error, :unauthorized}
      end

      assert Repo.aggregate(SecurityPolicy, :count) == 0
      assert policy_events() == []
    end

    test "a disabled org-admin is refused" do
      {_org, admin} = org_with_admin()

      from(u in Kanban.Accounts.User, where: u.id == ^admin.id)
      |> Repo.update_all(set: [disabled_at: @now])

      assert SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"}) ==
               {:error, :unauthorized}
    end

    test "invalid values return the changeset and write nothing" do
      {_org, admin} = org_with_admin()

      assert {:error, %Ecto.Changeset{} = cs} =
               SecurityPolicies.update_policy(admin, %{"audit_retention_days" => "30"})

      assert errors_on(cs).audit_retention_days != []
      assert Repo.aggregate(SecurityPolicy, :count) == 0
    end
  end

  describe "grace_deadline/2 and two_factor_status/3" do
    test "the deadline is the later of enforced_at and joining, plus the grace days" do
      policy = %SecurityPolicy{
        two_factor_enforced_at: ~U[2026-10-01 00:00:00Z],
        two_factor_grace_days: 7
      }

      early = %OrganizationMember{inserted_at: ~U[2026-01-01 00:00:00Z]}
      late = %OrganizationMember{inserted_at: ~U[2026-10-10 00:00:00Z]}

      assert SecurityPolicies.grace_deadline(policy, early) == ~U[2026-10-08 00:00:00Z]
      assert SecurityPolicies.grace_deadline(policy, late) == ~U[2026-10-17 00:00:00Z]
    end

    test "reports not_required, grace, overdue and enrolled" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)

      assert SecurityPolicies.two_factor_status_for_user(member) == :not_required
      assert SecurityPolicies.two_factor_status_for_user(user_fixture()) == :not_required

      {:ok, policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      deadline = DateTime.add(policy.two_factor_enforced_at, 7 * @day, :second)

      assert SecurityPolicies.two_factor_status_for_user(member) == {:grace, deadline}

      assert SecurityPolicies.two_factor_status_for_user(
               member,
               DateTime.add(deadline, 1, :second)
             ) ==
               {:overdue, deadline}

      assert SecurityPolicies.two_factor_status_for_user(member, deadline) == {:overdue, deadline}

      TwoFactorHelpers.enroll(member)

      assert SecurityPolicies.two_factor_status_for_user(member, DateTime.add(deadline, 1, :day)) ==
               :enrolled
    end

    test "a member who joins after the policy is enabled gets their own grace period" do
      {org, admin} = org_with_admin()
      {:ok, policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      newcomer = user_fixture()
      organization_member_fixture(org, newcomer)
      joined = DateTime.add(policy.two_factor_enforced_at, 20 * @day, :second)
      backdate_membership(newcomer, joined)

      assert SecurityPolicies.two_factor_status_for_user(
               newcomer,
               DateTime.add(joined, @day, :second)
             ) ==
               {:grace, DateTime.add(joined, 7 * @day, :second)}
    end

    test "turning the policy off, or leaving the Organization, ends the requirement" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      later = DateTime.add(DateTime.utc_now(), 30 * @day, :second)

      assert {:overdue, _} = SecurityPolicies.two_factor_status_for_user(member, later)
      assert SecurityPolicies.two_factor_required?(member)

      from(m in OrganizationMember, where: m.user_id == ^member.id) |> Repo.delete_all()
      assert SecurityPolicies.two_factor_status_for_user(member, later) == :not_required
      refute SecurityPolicies.two_factor_required?(member)

      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "false"})
      assert SecurityPolicies.two_factor_status_for_user(admin, later) == :not_required
      refute SecurityPolicies.two_factor_required?(admin)
    end

    test "re-joining keeps the grace period that already started" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      {:ok, policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      deadline = DateTime.add(policy.two_factor_enforced_at, 7 * @day, :second)

      # Removed and re-added before their status was ever read, ten days on.
      from(m in OrganizationMember, where: m.user_id == ^member.id) |> Repo.delete_all()
      organization_member_fixture(org, member)
      backdate_membership(member, DateTime.add(policy.two_factor_enforced_at, 10 * @day, :second))

      assert SecurityPolicies.two_factor_status_for_user(
               member,
               DateTime.add(policy.two_factor_enforced_at, 11 * @day, :second)
             ) == {:overdue, deadline}
    end

    test "a newcomer's grace is recorded on first read and kept across a re-join" do
      {org, admin} = org_with_admin()
      {:ok, policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      newcomer = user_fixture()
      organization_member_fixture(org, newcomer)
      joined = DateTime.add(policy.two_factor_enforced_at, 2 * @day, :second)
      backdate_membership(newcomer, joined)
      deadline = DateTime.add(joined, 7 * @day, :second)

      assert SecurityPolicies.two_factor_status_for_user(newcomer, joined) == {:grace, deadline}

      from(m in OrganizationMember, where: m.user_id == ^newcomer.id) |> Repo.delete_all()
      organization_member_fixture(org, newcomer)
      rejoined = DateTime.add(joined, 8 * @day, :second)
      backdate_membership(newcomer, rejoined)

      assert SecurityPolicies.two_factor_status_for_user(newcomer, rejoined) ==
               {:overdue, deadline}
    end

    test "turning the requirement off and on again starts everyone's grace again" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      {:ok, first} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      assert {:grace, _} = SecurityPolicies.two_factor_status_for_user(member)

      {:ok, _off} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "false"})

      later = DateTime.add(first.two_factor_enforced_at, 30 * @day, :second)
      restamp = from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      {:ok, second} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      Repo.update_all(restamp, set: [two_factor_enforced_at: later])
      second = %{second | two_factor_enforced_at: later}

      assert SecurityPolicies.two_factor_status_for_user(member, later) ==
               {:grace, DateTime.add(second.two_factor_enforced_at, 7 * @day, :second)}
    end

    test "someone who first joins after the requirement was turned on again gets their own grace" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      {:ok, first} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      assert {:grace, _} = SecurityPolicies.two_factor_status_for_user(member)

      # They leave; the requirement is turned off and on again; they come back.
      from(m in OrganizationMember, where: m.user_id == ^member.id) |> Repo.delete_all()
      {:ok, _off} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "false"})
      {:ok, _on} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      reenforced = DateTime.add(first.two_factor_enforced_at, 30 * @day, :second)

      from(p in SecurityPolicy, where: p.organization_id == ^org.id)
      |> Repo.update_all(set: [two_factor_enforced_at: reenforced])

      organization_member_fixture(org, member)
      rejoined = DateTime.add(reenforced, 5 * @day, :second)
      backdate_membership(member, rejoined)

      deadline = DateTime.add(rejoined, 7 * @day, :second)
      assert SecurityPolicies.two_factor_status_for_user(member, rejoined) == {:grace, deadline}

      # That start is now the one kept: a further re-join does not extend it.
      from(m in OrganizationMember, where: m.user_id == ^member.id) |> Repo.delete_all()
      organization_member_fixture(org, member)
      again = DateTime.add(rejoined, 8 * @day, :second)
      backdate_membership(member, again)

      assert SecurityPolicies.two_factor_status_for_user(member, again) == {:overdue, deadline}
    end

    test "the org-admin who enables the policy without two-factor gets the same grace period" do
      {_org, admin} = org_with_admin()
      {:ok, policy} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

      assert SecurityPolicies.two_factor_status_for_user(admin, policy.two_factor_enforced_at) ==
               {:grace, DateTime.add(policy.two_factor_enforced_at, 7 * @day, :second)}
    end
  end

  describe "hide_titles?/1" do
    test "hide_titles? is true for a member of an org with the policy on" do
      {org, admin} = org_with_admin()
      member = user_fixture()
      organization_member_fixture(org, member)
      {_other_org, other_admin} = org_with_admin()

      refute SecurityPolicies.hide_titles?(member)

      {:ok, _} =
        SecurityPolicies.update_policy(admin, %{"hide_titles_in_notifications" => "true"})

      assert SecurityPolicies.hide_titles?(member)
      assert SecurityPolicies.hide_titles?(admin)
      assert Kanban.Organizations.hide_titles?(member)
      refute SecurityPolicies.hide_titles?(other_admin)

      {:ok, _} =
        SecurityPolicies.update_policy(admin, %{"hide_titles_in_notifications" => "false"})

      refute SecurityPolicies.hide_titles?(member)
    end

    test "a user in no organization is false" do
      refute SecurityPolicies.hide_titles?(user_fixture())
    end

    test "a member whose Organization has no policy row, or another setting only, is false" do
      {_org, admin} = org_with_admin()
      refute SecurityPolicies.hide_titles?(admin)

      {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})
      refute SecurityPolicies.hide_titles?(admin)
    end
  end

  describe "list_audit_retention/0" do
    test "lists only Organizations with a retention period" do
      {org, admin} = org_with_admin()
      {_other, other_admin} = org_with_admin()
      {:ok, _} = SecurityPolicies.update_policy(admin, %{"audit_retention_days" => "120"})
      {:ok, _} = SecurityPolicies.update_policy(other_admin, %{"require_two_factor" => "true"})

      assert SecurityPolicies.list_audit_retention() == [
               %{organization_id: org.id, audit_retention_days: 120}
             ]
    end
  end
end
