defmodule Kanban.Repo.Migrations.AddLagMeasuredSlotToAuditStreamCursors do
  @moduledoc """
  The 15-minute slot a destination's lag was last measured in (D432, design
  §13.1).

  The minute sweep claims a destination's slot by moving this column forward
  in one conditional UPDATE before it emits `lag_measured`, so two sweeps of
  the same slot, a retried sweep or two nodes running the cron measure each
  destination once. NULL means never measured; the first sweep of its slot
  claims it.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_stream_cursors) do
      add :lag_measured_slot, :utc_datetime_usec
    end
  end
end
