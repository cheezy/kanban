defmodule Kanban.AuditLog.OrganizationScopeTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.OrganizationScope
  alias Kanban.Organizations.OrganizationMember

  setup do
    organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :org_admin)
    site_admin = admin_fixture()

    %{organization: organization, member: member, site_admin: site_admin}
  end

  defp insert_event!(organization, actor, inserted_at, attrs) do
    Repo.insert!(%AuditEvent{
      action: Keyword.get(attrs, :action, "organization_updated"),
      organization_id: organization.id,
      actor_user_id: actor && actor.id,
      ip: Keyword.get(attrs, :ip),
      metadata: Keyword.get(attrs, :metadata, %{}),
      inserted_at: inserted_at
    })
  end

  defp preloaded(events), do: Repo.preload(events, :actor_user)

  describe "redact_outside_actors/2" do
    test "strips a non-member actor's link, email, IP and identity metadata", %{
      organization: organization,
      site_admin: site_admin
    } do
      event =
        insert_event!(organization, site_admin, ~U[2026-10-01 00:00:00.000000Z],
          ip: "203.0.113.9",
          metadata: %{
            "user_id" => site_admin.id,
            "email" => site_admin.email,
            "ip" => "203.0.113.9",
            "organization_id" => organization.id
          }
        )

      assert [redacted] =
               [event] |> preloaded() |> OrganizationScope.redact_outside_actors(organization.id)

      assert redacted.actor_redacted
      assert redacted.actor_user_id == nil
      assert redacted.actor_user == nil
      assert redacted.ip == nil
      assert redacted.metadata == %{"organization_id" => organization.id}
      refute inspect(redacted) =~ site_admin.email
    end

    test "keeps a member actor unchanged", %{organization: organization, member: member} do
      event =
        insert_event!(organization, member, ~U[2026-10-01 00:00:00.000000Z],
          ip: "198.51.100.4",
          metadata: %{"user_id" => member.id}
        )

      [event] = preloaded([event])
      assert OrganizationScope.redact_outside_actors([event], organization.id) == [event]
    end

    test "a member of another Organization is outside this one", %{organization: organization} do
      outsider = user_fixture()
      organization_member_fixture(organization_fixture(), outsider, :org_admin)
      event = insert_event!(organization, outsider, ~U[2026-10-01 00:00:00.000000Z], [])

      assert [%{actor_redacted: true}] =
               OrganizationScope.redact_outside_actors([event], organization.id)
    end

    test "an event with no actor is unchanged", %{organization: organization} do
      event = insert_event!(organization, nil, ~U[2026-10-01 00:00:00.000000Z], ip: "192.0.2.1")

      assert OrganizationScope.redact_outside_actors([event], organization.id) == [event]
    end

    test "an unlinked actor id kept only in the metadata is checked too", %{
      organization: organization,
      member: member
    } do
      outside =
        insert_event!(organization, nil, ~U[2026-10-01 00:00:00.000000Z],
          metadata: %{"user_id" => 2_000_000_000}
        )

      inside =
        insert_event!(organization, nil, ~U[2026-10-02 00:00:00.000000Z],
          metadata: %{"user_id" => member.id}
        )

      assert [%{actor_redacted: true, metadata: %{}}, %{actor_redacted: false}] =
               OrganizationScope.redact_outside_actors([outside, inside], organization.id)
    end

    test "an empty batch needs no query", %{organization: organization} do
      assert OrganizationScope.redact_outside_actors([], organization.id) == []
    end
  end

  describe "membership judged when the event is written" do
    defp record!(actor, organization) do
      :ok =
        AuditLog.event(:organization_updated,
          user_id: actor && actor.id,
          organization_id: organization && organization.id
        )

      AuditEvent |> order_by(desc: :id) |> limit(1) |> Repo.one!()
    end

    test "AuditLog.event/2 stores whether the actor was a member at that moment", %{
      organization: organization,
      member: member,
      site_admin: site_admin
    } do
      assert record!(member, organization).actor_in_organization == true
      assert record!(site_admin, organization).actor_in_organization == false
      assert record!(nil, organization).actor_in_organization == nil
      assert record!(member, nil).actor_in_organization == nil
    end

    test "a departed org-admin's past actions stay visible", %{
      organization: organization,
      member: member
    } do
      event = record!(member, organization)
      OrganizationMember |> where(user_id: ^member.id) |> Repo.delete_all()

      assert [%{actor_redacted: false, actor_user_id: actor_id}] =
               OrganizationScope.redact_outside_actors([event], organization.id)

      assert actor_id == member.id
    end

    test "staff who join later do not uncover what staff did before", %{
      organization: organization,
      site_admin: site_admin
    } do
      event = record!(site_admin, organization)
      organization_member_fixture(organization, site_admin, :org_admin)

      assert [%{actor_redacted: true, ip: nil, actor_user_id: nil}] =
               OrganizationScope.redact_outside_actors([event], organization.id)

      assert record!(site_admin, organization).actor_in_organization == true
    end

    test "a row written before the record falls back to current membership", %{
      organization: organization,
      member: member,
      site_admin: site_admin
    } do
      legacy_member = insert_event!(organization, member, ~U[2026-10-01 00:00:00.000000Z], [])
      legacy_admin = insert_event!(organization, site_admin, ~U[2026-10-02 00:00:00.000000Z], [])
      assert legacy_member.actor_in_organization == nil

      assert [%{actor_redacted: false}, %{actor_redacted: true}] =
               OrganizationScope.redact_outside_actors(
                 [legacy_member, legacy_admin],
                 organization.id
               )
    end

    test "actor_member?/3 is nil without an actor or an Organization", %{
      organization: organization,
      member: member
    } do
      assert OrganizationScope.actor_member?(nil, organization.id) == nil
      assert OrganizationScope.actor_member?(member.id, nil) == nil
      assert OrganizationScope.actor_member?(member.id, organization.id) == true
      assert OrganizationScope.actor_member?(member.id, organization_fixture().id) == false
    end
  end

  describe "the :redact_actors_outside option" do
    setup %{organization: organization, member: member, site_admin: site_admin} do
      by_admin =
        insert_event!(organization, site_admin, ~U[2026-10-01 00:00:00.000000Z],
          ip: "203.0.113.9",
          metadata: %{"user_id" => site_admin.id}
        )

      by_member =
        insert_event!(organization, member, ~U[2026-10-02 00:00:00.000000Z],
          action: "org_audit_log_exported",
          metadata: %{"user_id" => member.id}
        )

      %{by_admin: by_admin, by_member: by_member}
    end

    test "list_events_page/2 redacts outside actors only when asked", %{
      organization: organization,
      site_admin: site_admin,
      member: member
    } do
      filters = [organization_id: organization.id]

      scoped = AuditLog.list_events_page(filters, redact_actors_outside: organization.id)
      assert [%{actor_user: %{email: email}}, %{actor_redacted: true, ip: nil}] = scoped.entries
      assert email == member.email

      unscoped = AuditLog.list_events_page(filters)
      assert [_member_event, %{actor_user: %{email: admin_email}}] = unscoped.entries
      assert admin_email == site_admin.email
    end

    test "export_stream/3 never exports an outside actor's id, email or IP", %{
      organization: organization,
      site_admin: site_admin,
      member: member
    } do
      csv =
        [organization_id: organization.id]
        |> AuditLog.export_stream(:csv, redact_actors_outside: organization.id, batch_size: 1)
        |> Enum.join()

      refute csv =~ site_admin.email
      refute csv =~ "203.0.113.9"
      assert csv =~ member.email

      json =
        [organization_id: organization.id]
        |> AuditLog.export_stream(:json, redact_actors_outside: organization.id)
        |> Enum.join()
        |> Jason.decode!()

      assert [%{"actor_email" => member_email}, admin_row] = json
      assert member_email == member.email
      assert admin_row["actor_user_id"] == nil
      assert admin_row["actor_email"] == nil
      assert admin_row["ip"] == nil
      refute Map.has_key?(admin_row["metadata"], "user_id")
    end
  end
end
