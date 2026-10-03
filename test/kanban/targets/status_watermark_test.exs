defmodule Kanban.Targets.StatusWatermarkTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.TargetsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.StatusWatermark

  @observed ~U[2026-06-09 10:30:45Z]

  describe "transition/2" do
    test "notifies on a move into at_risk or missed, including the first observation" do
      assert StatusWatermark.transition(nil, :at_risk) == :notify
      assert StatusWatermark.transition(nil, :missed) == :notify
      assert StatusWatermark.transition("on_track", :at_risk) == :notify
      assert StatusWatermark.transition("at_risk", :missed) == :notify
      assert StatusWatermark.transition("missed", :at_risk) == :notify
      assert StatusWatermark.transition("complete", :missed) == :notify
    end

    test "does nothing when the status is the one recorded" do
      for status <- [:on_track, :at_risk, :missed, :complete] do
        assert status |> Atom.to_string() |> StatusWatermark.transition(status) == :unchanged
      end
    end

    test "records a move into on_track or complete silently" do
      assert StatusWatermark.transition("at_risk", :on_track) == :record
      assert StatusWatermark.transition("missed", :complete) == :record
      assert StatusWatermark.transition(nil, :on_track) == :record
      assert StatusWatermark.transition(nil, :complete) == :record
    end
  end

  describe "list_active_target_owners/0" do
    test "lists each owner of an active target once, by id" do
      first = user_fixture()
      second = user_fixture()
      delivery_target_fixture(second)
      delivery_target_fixture(first)
      delivery_target_fixture(first)

      ids = Enum.map(Targets.list_active_target_owners(), & &1.id)

      assert ids == Enum.sort([first.id, second.id])
    end

    test "skips owners whose targets are all archived, and targets with no owner" do
      archived_owner = user_fixture()
      target = delivery_target_fixture(archived_owner)

      {:ok, _} =
        target
        |> DeliveryTarget.archive_changeset(%{archived_at: DateTime.utc_now()})
        |> Repo.update()

      {:ok, _ownerless} =
        %DeliveryTarget{}
        |> DeliveryTarget.changeset(%{name: "Nobody's", target_date: ~D[2026-12-31]})
        |> Repo.insert()

      assert Targets.list_active_target_owners() == []
    end
  end

  describe "record_observed_status/3" do
    setup do
      owner = user_fixture()
      %{owner: owner, target: delivery_target_fixture(owner)}
    end

    test "stores the status and when it changed, without touching updated_at", %{target: target} do
      assert {:ok, recorded} = Targets.record_observed_status(target, :at_risk, @observed)

      assert recorded.last_notified_status == "at_risk"
      assert recorded.status_changed_at == @observed
      assert recorded.updated_at == target.updated_at
      assert Repo.get!(DeliveryTarget, target.id).last_notified_status == "at_risk"
    end

    test "truncates the stamp to the second", %{target: target} do
      {:ok, recorded} =
        Targets.record_observed_status(target, :missed, ~U[2026-06-09 10:30:45.123456Z])

      assert recorded.status_changed_at == @observed
    end

    test "is stale when the stored watermark changed underneath", %{target: target} do
      {:ok, _} = Targets.record_observed_status(target, :at_risk, @observed)

      # `target` still carries the nil watermark it was loaded with.
      assert {:error, :stale} = Targets.record_observed_status(target, :missed, @observed)
      assert Repo.get!(DeliveryTarget, target.id).last_notified_status == "at_risk"
    end

    test "rejects an unknown status", %{target: target} do
      assert {:error, %Ecto.Changeset{}} =
               Targets.record_observed_status(target, :late, @observed)

      assert Repo.get!(DeliveryTarget, target.id).last_notified_status == nil
    end

    test "editing the target through the form cannot set the watermark", ctx do
      owner_scope = Scope.for_user(ctx.owner)

      {:ok, updated} =
        Targets.update_target(owner_scope, ctx.target, %{
          "name" => "Renamed",
          "last_notified_status" => "missed",
          "status_changed_at" => DateTime.to_iso8601(@observed)
        })

      assert updated.name == "Renamed"
      assert updated.last_notified_status == nil
      assert updated.status_changed_at == nil
    end
  end
end
