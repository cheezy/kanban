defmodule Kanban.Repo.Migrations.AddAfterGoalTrackingToTasks do
  use Ecto.Migration

  @moduledoc """
  Adds the columns the goal Done transition needs to gate on the
  agent-reported after_goal hook result (W493). All three columns are
  nilable — they are only populated on goals once their last child
  completes; they remain NULL for work/defect tasks and for goals whose
  final child has not yet completed.

  Columns
  -------
  - `after_goal_status` (enum :pending | :succeeded, nilable): once the
    last child of a goal completes the column flips to `:pending`; a
    successful agent report or the Oban grace-window fallback flips it
    to `:succeeded` and unblocks the goal Done transition.
  - `after_goal_result` (map / jsonb, nilable): the most-recent agent
    report payload (`%{exit_code, output, duration_ms}`). Latest report
    wins (the auditable history of all reports lives in
    `after_goal_attempts`).
  - `after_goal_attempts` (array of jsonb, default `[]`): the audit log
    of every report received. Pitfall: \"the latest report wins but must
    be auditable\" — every attempt is appended here regardless of which
    overwrites `after_goal_result`.
  """

  def change do
    # Enum stored as a string ("pending" / "succeeded") to keep the
    # write path simple and migration-friendly — Ecto.Enum on the schema
    # casts between atoms and strings transparently.
    execute(
      "CREATE TYPE after_goal_status AS ENUM ('pending', 'succeeded')",
      "DROP TYPE after_goal_status"
    )

    alter table(:tasks) do
      add :after_goal_status, :after_goal_status
      add :after_goal_result, :map
      add :after_goal_attempts, {:array, :map}, default: [], null: false
    end
  end
end
