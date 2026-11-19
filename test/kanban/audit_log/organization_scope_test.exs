defmodule Kanban.AuditLog.OrganizationScopeTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.OrganizationScope
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Reviews
  alias Kanban.Tasks

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
      actor_in_organization: Keyword.get(attrs, :in_organization),
      ip: Keyword.get(attrs, :ip),
      metadata: Keyword.get(attrs, :metadata, %{}),
      inserted_at: inserted_at
    })
  end

  defp preloaded(events), do: Repo.preload(events, :actor_user)

  # A non-member probe's event, as a row holding a text user_id would read.
  defp text_id_event!(organization, probe, actor, inserted_at) do
    insert_event!(organization, actor, inserted_at,
      ip: "203.0.113.77",
      metadata: %{
        "user_id" => Integer.to_string(probe.id),
        "email" => probe.email,
        "ip" => "203.0.113.77",
        "name" => "D440-probe"
      }
    )
  end

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

      null_id =
        insert_event!(organization, nil, ~U[2026-10-02 00:00:00.000000Z],
          metadata: %{"user_id" => nil, "name" => "D440-probe"}
        )

      assert OrganizationScope.redact_outside_actors([event, null_id], organization.id) ==
               [event, null_id]
    end

    test "a pre-flag event with a text user_id of a deleted non-member is redacted", %{
      organization: organization
    } do
      probe = user_fixture()
      event = text_id_event!(organization, probe, probe, ~U[2026-10-01 00:00:00.000000Z])
      Repo.delete!(probe)

      event = AuditEvent |> Repo.get!(event.id) |> Repo.preload(:actor_user)
      assert event.actor_user_id == nil
      assert event.actor_in_organization == nil

      assert [redacted] = OrganizationScope.redact_outside_actors([event], organization.id)
      assert redacted.actor_redacted
      assert redacted.ip == nil
      assert redacted.metadata == %{"name" => "D440-probe"}
      refute inspect(redacted) =~ probe.email
    end

    test "a pre-flag event with a text user_id of an unlinked non-member is redacted", %{
      organization: organization
    } do
      probe = user_fixture()
      event = text_id_event!(organization, probe, nil, ~U[2026-10-01 00:00:00.000000Z])

      assert [%{actor_redacted: true, ip: nil, metadata: %{"name" => "D440-probe"}}] =
               OrganizationScope.redact_outside_actors([event], organization.id)
    end

    test "a pre-flag event with a text user_id of a current member is kept", %{
      organization: organization,
      member: member
    } do
      event =
        insert_event!(organization, nil, ~U[2026-10-01 00:00:00.000000Z],
          ip: "198.51.100.4",
          metadata: %{"user_id" => Integer.to_string(member.id), "email" => member.email}
        )

      assert OrganizationScope.redact_outside_actors([event], organization.id) == [event]
    end

    test "a pre-flag event with an unparseable or out-of-range user_id is redacted", %{
      organization: organization,
      member: member
    } do
      id = Integer.to_string(member.id)

      values = [
        " " <> id,
        id <> " ",
        id <> "\n",
        "0" <> id,
        "+" <> id,
        "-" <> id,
        id <> "abc",
        "0",
        "",
        "9223372036854775808",
        String.duplicate("9", 30),
        -member.id,
        0,
        9_223_372_036_854_775_808,
        member.id * 1.0,
        true,
        %{"id" => member.id},
        [member.id]
      ]

      events =
        for value <- values do
          insert_event!(organization, nil, ~U[2026-10-01 00:00:00.000000Z],
            ip: "203.0.113.9",
            metadata: %{"user_id" => value, "email" => member.email, "name" => "D440-probe"}
          )
        end

      redacted = OrganizationScope.redact_outside_actors(events, organization.id)

      for {value, event} <- Enum.zip(values, redacted) do
        assert event.actor_redacted, "user_id #{inspect(value)} was not redacted"
        assert event.metadata == %{"name" => "D440-probe"}
        assert event.ip == nil
      end
    end

    test "a pre-flag text user_id is judged by membership at each read", %{
      organization: organization
    } do
      leaver = user_fixture()
      membership = organization_member_fixture(organization, leaver, :org_admin)
      joiner = user_fixture()
      left = text_id_event!(organization, leaver, nil, ~U[2026-10-01 00:00:00.000000Z])
      joined = text_id_event!(organization, joiner, nil, ~U[2026-10-02 00:00:00.000000Z])

      assert [%{actor_redacted: false}, %{actor_redacted: true}] =
               OrganizationScope.redact_outside_actors([left, joined], organization.id)

      OrganizationMember |> Repo.get!(membership.id) |> Repo.delete!()
      organization_member_fixture(organization, joiner, :org_admin)

      assert [%{actor_redacted: true, metadata: %{"name" => "D440-probe"}}, kept] =
               OrganizationScope.redact_outside_actors([left, joined], organization.id)

      assert kept == joined
    end

    test "a flagged event is judged by its flag, whatever its user_id", %{
      organization: organization,
      member: member
    } do
      kept =
        insert_event!(organization, nil, ~U[2026-10-01 00:00:00.000000Z],
          in_organization: true,
          metadata: %{"user_id" => "not an id"}
        )

      dropped =
        insert_event!(organization, nil, ~U[2026-10-02 00:00:00.000000Z],
          in_organization: false,
          metadata: %{"user_id" => Integer.to_string(member.id)}
        )

      assert [^kept, %{actor_redacted: true, metadata: %{}}] =
               OrganizationScope.redact_outside_actors([kept, dropped], organization.id)
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
      probe = user_fixture()
      text_id_event!(organization, probe, probe, ~U[2026-10-03 00:00:00.000000Z])
      Repo.delete!(probe)

      csv =
        [organization_id: organization.id]
        |> AuditLog.export_stream(:csv, redact_actors_outside: organization.id, batch_size: 1)
        |> Enum.join()

      refute csv =~ site_admin.email
      refute csv =~ "203.0.113.9"
      refute csv =~ probe.email
      refute csv =~ "203.0.113.77"
      assert csv =~ member.email

      json =
        [organization_id: organization.id]
        |> AuditLog.export_stream(:json, redact_actors_outside: organization.id)
        |> Enum.join()
        |> Jason.decode!()

      assert [probe_row, %{"actor_email" => member_email}, admin_row] = json
      assert member_email == member.email

      for row <- [admin_row, probe_row] do
        assert row["actor_user_id"] == nil
        assert row["actor_email"] == nil
        assert row["ip"] == nil
        refute Map.has_key?(row["metadata"], "user_id")
      end

      assert probe_row["metadata"] == %{"name" => "D440-probe"}
    end
  end

  describe "review audit events" do
    defp pending_review_task!(column) do
      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          needs_review: true,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          completed_by_agent: "Claude"
        })

      task
    end

    test "review audit rows appear in the board's Organization audit log", %{
      organization: organization,
      member: member
    } do
      board = member |> board_fixture() |> move_board_to_organization(organization)
      join_board_organization(board, member)
      review = column_fixture(board, %{name: "Review", position: 1})
      _done = column_fixture(board, %{name: "Done", position: 2})
      approved = pending_review_task!(review)
      changes = pending_review_task!(review)
      scope = Scope.for_user(member)

      assert {:ok, _} = Reviews.approve_review(scope, approved, via: :web)

      assert {:ok, _} =
               Reviews.request_changes_review(scope, changes, review_notes: "Fix it", via: :web)

      assert [%AuditEvent{} = event] =
               AuditLog.list_events(organization_id: organization.id, action: :review_approved)

      assert event.organization_id == organization.id
      assert event.actor_in_organization == true
      assert event.metadata["task_id"] == approved.id

      assert [%AuditEvent{metadata: %{"task_id" => changes_id}}] =
               AuditLog.list_events(
                 organization_id: organization.id,
                 action: :review_changes_requested
               )

      assert changes_id == changes.id

      actions = AuditLog.list_actions(organization_id: organization.id)
      assert "review_approved" in actions
      assert "review_changes_requested" in actions
    end

    test "a review on a personal board has no Organization", %{member: member} do
      board = board_fixture(member)
      review = column_fixture(board, %{name: "Review", position: 1})
      _done = column_fixture(board, %{name: "Done", position: 2})
      task = pending_review_task!(review)

      assert {:ok, _} = member |> Scope.for_user() |> Reviews.approve_review(task)

      assert [%AuditEvent{organization_id: nil, metadata: metadata}] =
               AuditLog.list_events(action: :review_approved, actor_user_id: member.id)

      refute Map.has_key?(metadata, "organization_id")
    end
  end
end
