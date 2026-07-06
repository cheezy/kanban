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
