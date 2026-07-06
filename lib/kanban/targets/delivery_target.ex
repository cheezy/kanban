defmodule Kanban.Targets.DeliveryTarget do
  @moduledoc """
  A delivery target groups goals toward a dated outcome (name + target_date).

  A goal-type task may belong to a delivery target via `tasks.target_id`
  (see `Kanban.Tasks.Task`). Targets are owned by a user; the owner reference
  is nullable and nullifies when the user is removed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "delivery_targets" do
    field :name, :string
    field :target_date, :date
    field :description, :string

    belongs_to :owner, Kanban.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(delivery_target, attrs) do
    # :owner_id is intentionally NOT cast — ownership is set server-side on the
    # struct (%DeliveryTarget{owner_id: current_user.id}), never from request
    # params. Casting it would let a caller forge a target's owner via
    # target[owner_id]. This mirrors the D94 sender_id pattern in
    # Kanban.Messages.Message. The foreign_key_constraint below still guards
    # DB-level integrity.
    delivery_target
    |> cast(attrs, [:name, :target_date, :description])
    |> validate_required([:name, :target_date])
    |> foreign_key_constraint(:owner_id)
  end
end
