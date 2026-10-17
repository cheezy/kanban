defmodule Kanban.AuditLog.OrganizationTest do
  @moduledoc """
  The `audit_events.organization_id` link (W2397): persistence, the stale-id
  retry, the `organization_id` filter, the scoped action list and the scoped
  export.
  """
  use Kanban.DataCase, async: true

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent

  @max_bigint 9_223_372_036_854_775_807

  defp only_event! do
    assert [event] = Repo.all(AuditEvent)
    event
  end

  defp insert_event!(action, organization, inserted_at) do
    Repo.insert!(%AuditEvent{
      action: action,
      organization_id: organization && organization.id,
      inserted_at: inserted_at,
      metadata: %{}
    })
  end

  defp scalar(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  describe "the migration" do
    test "the foreign key references organizations with no cascade" do
      assert scalar("""
             SELECT confdeltype FROM pg_constraint
             WHERE conrelid = 'audit_events'::regclass
               AND confrelid = 'organizations'::regclass AND contype = 'f'
             """) == "a"
    end

    test "the column is nullable and indexed on organization_id, inserted_at and id" do
      assert scalar("""
             SELECT is_nullable FROM information_schema.columns
             WHERE table_name = 'audit_events' AND column_name = 'organization_id'
             """) == "YES"

      assert scalar("""
             SELECT pg_get_indexdef(indexrelid) FROM pg_index
             WHERE indrelid = 'audit_events'::regclass
               AND indexrelid = 'audit_events_organization_id_inserted_at_id_index'::regclass
             """) =~ "(organization_id, inserted_at, id)"
    end

    test "an Organization with audit events cannot be deleted, so no audit row is ever edited" do
      organization = organization_fixture()
      AuditLog.event(:organization_updated, organization_id: organization.id)

      # The savepoint keeps the refused delete from aborting the sandbox.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transact(fn -> Repo.delete(organization) end)
      end

      assert only_event!().organization_id == organization.id
    end
  end

  describe "persistence of organization_id" do
    test "event/2 stores an integer organization_id in the column and the metadata" do
      organization = organization_fixture()
      user = user_fixture()

      assert :ok =
               AuditLog.event(:organization_updated,
                 user_id: user.id,
                 organization_id: organization.id
               )

      event = only_event!()
      assert event.organization_id == organization.id
      assert event.actor_user_id == user.id
      assert event.metadata["organization_id"] == organization.id
    end

    test "an event without organization_id stores nil, even when another id matches an Organization" do
      organization = organization_fixture()
      AuditLog.event(:sudo_mode_entered, workspace_id: organization.id)

      assert only_event!().organization_id == nil
    end

    test "an out-of-range or non-integer organization_id stores nil and stays in the metadata" do
      for value <- [0, -4, @max_bigint + 1, "12", 1.5] do
        AuditLog.event(:organization_updated, organization_id: value)
      end

      events = AuditLog.list_events([], order: :asc)
      assert Enum.map(events, & &1.organization_id) == [nil, nil, nil, nil, nil]

      assert Enum.map(events, & &1.metadata["organization_id"]) ==
               [0, -4, @max_bigint + 1, "12", 1.5]
    end
  end

  describe "a stale organization_id" do
    test "is stored without the column value, keeping the id in the metadata" do
      log =
        capture_log([level: :error], fn ->
          assert :ok = AuditLog.event(:organization_updated, organization_id: 2_000_000_000)
        end)

      refute log =~ "security_audit_persist_failed"

      event = only_event!()
      assert event.action == "organization_updated"
      assert event.organization_id == nil
      assert event.metadata == %{"organization_id" => 2_000_000_000}
    end

    test "inside a caller's transaction keeps the event and the transaction" do
      organization = organization_fixture()

      assert {:ok, :committed} =
               Repo.transact(fn ->
                 assert :ok = AuditLog.event(:ghost_org, organization_id: 2_000_000_000)
                 assert :ok = AuditLog.event(:real_org, organization_id: organization.id)
                 {:ok, :committed}
               end)

      assert [ghost, real] = AuditLog.list_events([], order: :asc)
      assert {ghost.action, ghost.organization_id} == {"ghost_org", nil}
      assert real.organization_id == organization.id
    end

    test "together with a stale actor drops both links and keeps the event" do
      AuditLog.event(:ghost_both, user_id: 2_000_000_001, organization_id: 2_000_000_000)

      event = only_event!()
      assert {event.actor_user_id, event.organization_id} == {nil, nil}

      assert event.metadata == %{
               "user_id" => 2_000_000_001,
               "organization_id" => 2_000_000_000
             }
    end

    test "a stale actor with a real Organization keeps the Organization link" do
      organization = organization_fixture()
      AuditLog.event(:ghost_actor, user_id: 2_000_000_001, organization_id: organization.id)

      event = only_event!()
      assert {event.actor_user_id, event.organization_id} == {nil, organization.id}
    end
  end

  describe "the organization_id filter" do
    setup do
      org_a = organization_fixture()
      org_b = organization_fixture()
      base = ~U[2026-10-01 00:00:00.000000Z]

      a1 = insert_event!("organization_updated", org_a, base)
      a2 = insert_event!("org_admin_appointed", org_a, DateTime.add(base, 1))
      b1 = insert_event!("organization_created", org_b, DateTime.add(base, 2))
      none = insert_event!("login_failed", nil, DateTime.add(base, 3))

      %{org_a: org_a, org_b: org_b, a1: a1, a2: a2, b1: b1, none: none}
    end

    test "list_events/2 returns only the Organization's events", %{org_a: org_a, a1: a1, a2: a2} do
      assert AuditLog.list_events(organization_id: org_a.id) |> Enum.map(& &1.id) == [
               a2.id,
               a1.id
             ]
    end

    test "a nil organization_id applies no filter", %{a1: a1, a2: a2, b1: b1, none: none} do
      ids = AuditLog.list_events(organization_id: nil) |> Enum.map(& &1.id)
      assert ids == [none.id, b1.id, a2.id, a1.id]
    end

    test "list_events_page/2 pages within the Organization", %{org_a: org_a, a1: a1, a2: a2} do
      first = AuditLog.list_events_page([organization_id: org_a.id], limit: 1)
      assert Enum.map(first.entries, & &1.id) == [a2.id]

      cursor = Kanban.AuditLog.Query.decode_cursor(first.next_cursor)
      second = AuditLog.list_events_page([organization_id: org_a.id], limit: 1, cursor: cursor)
      assert Enum.map(second.entries, & &1.id) == [a1.id]
      assert second.next_cursor == nil
    end

    test "list_actions/1 lists only actions in the Organization's events", %{
      org_a: org_a,
      org_b: org_b
    } do
      assert AuditLog.list_actions(organization_id: org_a.id) ==
               ["org_admin_appointed", "organization_updated"]

      assert AuditLog.list_actions(organization_id: org_b.id) == ["organization_created"]

      assert AuditLog.list_actions() ==
               [
                 "login_failed",
                 "org_admin_appointed",
                 "organization_created",
                 "organization_updated"
               ]
    end

    test "list_actions/1 is empty for an Organization with no events" do
      assert AuditLog.list_actions(organization_id: organization_fixture().id) == []
    end

    test "export_stream/3 exports only the Organization's events", %{org_a: org_a} do
      json =
        [organization_id: org_a.id]
        |> AuditLog.export_stream(:json, batch_size: 1)
        |> Enum.join()
        |> Jason.decode!()

      assert Enum.map(json, & &1["action"]) == ["org_admin_appointed", "organization_updated"]
    end
  end
end
