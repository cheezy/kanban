defmodule Kanban.TargetsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  `Kanban.Targets.DeliveryTarget` entities.
  """

  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget

  @doc """
  Generate a delivery target owned by the given user.

  `owner_id` is set server-side on the struct (it is not castable), matching
  how the application assigns ownership from the authenticated user.
  """
  def delivery_target_fixture(owner, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Target #{System.unique_integer([:positive])}",
        target_date: ~D[2026-12-31]
      })

    {:ok, target} =
      %DeliveryTarget{owner_id: owner.id}
      |> DeliveryTarget.changeset(attrs)
      |> Repo.insert()

    target
  end
end
