defmodule Kanban.Targets.DeliveryTargetTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures

  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget

  describe "changeset/2" do
    test "requires name and target_date" do
      changeset = DeliveryTarget.changeset(%DeliveryTarget{}, %{})

      assert %{name: ["can't be blank"], target_date: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "rejects blank name" do
      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{name: "", target_date: ~D[2026-09-30]})

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires target_date when only a name is given" do
      changeset = DeliveryTarget.changeset(%DeliveryTarget{}, %{name: "Q3 launch"})

      assert %{target_date: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts valid attributes without an owner" do
      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{
          name: "Q3 launch",
          target_date: ~D[2026-09-30]
        })

      assert changeset.valid?
    end

    test "accepts an optional description" do
      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{
          name: "Q3 launch",
          target_date: ~D[2026-09-30],
          description: "Ship the redesigned board"
        })

      assert changeset.valid?
      assert get_change(changeset, :description) == "Ship the redesigned board"
    end

    test "does not cast owner_id from params" do
      user = user_fixture()

      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{
          name: "Q3 launch",
          target_date: ~D[2026-09-30],
          owner_id: user.id
        })

      # owner_id is intentionally not castable — ownership is set server-side.
      assert get_change(changeset, :owner_id) == nil
    end

    test "does not cast archived_at from params" do
      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{
          name: "Q3 launch",
          target_date: ~D[2026-09-30],
          archived_at: DateTime.utc_now()
        })

      # Archiving goes through archive_changeset/2 and the archive_target/2
      # completeness gate — an ordinary edit must never set archived_at.
      assert get_change(changeset, :archived_at) == nil
    end
  end

  describe "archive_changeset/2" do
    test "sets archived_at" do
      now = DateTime.utc_now()
      changeset = DeliveryTarget.archive_changeset(%DeliveryTarget{}, %{archived_at: now})

      assert changeset.valid?
      assert get_change(changeset, :archived_at) == now
    end

    test "clears archived_at to nil" do
      archived = %DeliveryTarget{archived_at: DateTime.utc_now()}
      changeset = DeliveryTarget.archive_changeset(archived, %{archived_at: nil})

      assert changeset.valid?
      assert get_change(changeset, :archived_at) == nil
    end

    test "does not cast owner_id from params" do
      user = user_fixture()
      other = user_fixture()

      changeset =
        DeliveryTarget.archive_changeset(%DeliveryTarget{owner_id: user.id}, %{
          archived_at: DateTime.utc_now(),
          owner_id: other.id
        })

      # Archiving must never be a path to forging ownership.
      assert get_change(changeset, :owner_id) == nil
    end

    test "does not cast the editable fields" do
      changeset =
        DeliveryTarget.archive_changeset(%DeliveryTarget{name: "Original"}, %{
          archived_at: DateTime.utc_now(),
          name: "Renamed",
          target_date: ~D[2027-01-01],
          description: "smuggled"
        })

      assert get_change(changeset, :name) == nil
      assert get_change(changeset, :target_date) == nil
      assert get_change(changeset, :description) == nil
    end
  end

  describe "status_changeset/2" do
    @observed ~U[2026-06-09 00:00:00Z]

    test "casts only the watermark fields" do
      user = user_fixture()
      other = user_fixture()

      changeset =
        DeliveryTarget.status_changeset(%DeliveryTarget{owner_id: user.id, name: "Original"}, %{
          last_notified_status: "at_risk",
          status_changed_at: @observed,
          name: "Renamed",
          owner_id: other.id,
          archived_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert get_change(changeset, :last_notified_status) == "at_risk"
      assert get_change(changeset, :status_changed_at) == @observed
      assert get_change(changeset, :name) == nil
      assert get_change(changeset, :owner_id) == nil
      assert get_change(changeset, :archived_at) == nil
    end

    test "requires both fields and a known status" do
      assert %{last_notified_status: ["can't be blank"], status_changed_at: ["can't be blank"]} =
               %DeliveryTarget{} |> DeliveryTarget.status_changeset(%{}) |> errors_on()

      assert %{last_notified_status: ["is invalid"]} =
               %DeliveryTarget{}
               |> DeliveryTarget.status_changeset(%{
                 last_notified_status: "late",
                 status_changed_at: @observed
               })
               |> errors_on()
    end

    test "the form changeset never casts the watermark fields" do
      changeset =
        DeliveryTarget.changeset(%DeliveryTarget{}, %{
          name: "Q3 launch",
          target_date: ~D[2026-09-30],
          last_notified_status: "missed",
          status_changed_at: @observed
        })

      assert get_change(changeset, :last_notified_status) == nil
      assert get_change(changeset, :status_changed_at) == nil
    end

    test "the archive changeset never casts the watermark fields" do
      changeset =
        DeliveryTarget.archive_changeset(%DeliveryTarget{}, %{
          archived_at: DateTime.utc_now(),
          last_notified_status: "missed",
          status_changed_at: @observed
        })

      assert get_change(changeset, :last_notified_status) == nil
      assert get_change(changeset, :status_changed_at) == nil
    end
  end

  describe "database constraints" do
    test "can insert a target with an owner set on the struct" do
      user = user_fixture()

      {:ok, target} =
        %DeliveryTarget{owner_id: user.id}
        |> DeliveryTarget.changeset(%{name: "hello", target_date: ~D[2026-09-30]})
        |> Repo.insert()

      assert target.id
      assert target.owner_id == user.id
    end

    test "owner_id becomes nil when the owner user is deleted" do
      user = user_fixture()

      {:ok, target} =
        %DeliveryTarget{owner_id: user.id}
        |> DeliveryTarget.changeset(%{name: "hi", target_date: ~D[2026-09-30]})
        |> Repo.insert()

      Repo.delete!(user)

      reloaded = Repo.get!(DeliveryTarget, target.id)
      assert reloaded.owner_id == nil
    end
  end

  describe "associations" do
    test "belongs_to :owner is preloadable" do
      user = user_fixture()

      {:ok, target} =
        %DeliveryTarget{owner_id: user.id}
        |> DeliveryTarget.changeset(%{name: "t", target_date: ~D[2026-09-30]})
        |> Repo.insert()

      reloaded = DeliveryTarget |> Repo.get!(target.id) |> Repo.preload(:owner)

      assert reloaded.owner.id == user.id
    end
  end
end
