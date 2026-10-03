defmodule Kanban.Targets.DeliveryTarget do
  @moduledoc """
  A delivery target groups goals toward a dated outcome (name + target_date).

  A goal-type task may belong to a delivery target via `tasks.target_id`
  (see `Kanban.Tasks.Task`). Targets are owned by a user; the owner reference
  is nullable and nullifies when the user is removed.

  `archived_at` is the archive flag: `nil` means active, a timestamp means
  archived. A target's delivery status is always derived at read time by
  `Kanban.Targets.Status.derive/4` (through
  `Kanban.Targets.list_targets_with_status/2`).

  `last_notified_status` and `status_changed_at` are NOT a stored status: they
  are the watermark `Kanban.Notifications.TargetStatusWorker` uses to notice a
  change and notify the owner once. They lag the derived status by up to an
  hour, are computed against UTC rather than a viewer's timezone, and no read
  path may display or trust them. Only `status_changeset/2` writes them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(on_track at_risk missed complete)

  schema "delivery_targets" do
    field :name, :string
    field :target_date, :date
    field :description, :string
    field :archived_at, :utc_datetime_usec
    field :last_notified_status, :string
    field :status_changed_at, :utc_datetime

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

  @doc """
  Sets or clears `archived_at` — pass a timestamp to archive, `nil` to
  unarchive.

  One changeset serves both directions, mirroring
  `Kanban.Tasks.Task.archive_changeset/2`, which `Kanban.Tasks.Lifecycle` uses
  to archive *and* to unarchive (by passing `archived_at: nil`).

  `:archived_at` is the only castable field. `:owner_id` in particular is not
  cast here for the same reason as in `changeset/2` above — archiving must
  never be a path to forging a target's owner.
  """
  def archive_changeset(delivery_target, attrs) do
    cast(delivery_target, attrs, [:archived_at])
  end

  @doc """
  Records the status the target-status sweeper observed and when it changed.

  Server-set only: built by `Kanban.Targets.StatusWatermark`, never from
  request params, and the only changeset that casts these two fields.
  `changeset/2` (the target form) and `archive_changeset/2` ignore them.
  """
  def status_changeset(delivery_target, attrs) do
    delivery_target
    |> cast(attrs, [:last_notified_status, :status_changed_at])
    |> validate_required([:last_notified_status, :status_changed_at])
    |> validate_inclusion(:last_notified_status, @statuses)
  end
end
