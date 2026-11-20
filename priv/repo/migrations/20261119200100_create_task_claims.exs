defmodule Kanban.Repo.Migrations.CreateTaskClaims do
  @moduledoc """
  Creates `task_claims`, one row per agent claim of a task: the task and the
  moment it was claimed (`Kanban.Tasks.TaskClaim`).

  Claims left no history before this: a claim writes no `task_history` row,
  and an unclaim or a released claim clears `tasks.claimed_at`. The decisions
  inbox needs to know whether a task was claimed after a `task_unclaimed`
  notification, so a released item clears on any later claim, even one that
  ends without a release (`Kanban.Decisions.Sources`).

  Only the task id and the time are stored, no user, so an account deletion
  leaves nothing behind here. Rows are deleted with their task. The index on
  `(task_id, claimed_at)` answers "the latest claim of these tasks".
  """
  use Ecto.Migration

  def change do
    create table(:task_claims) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :claimed_at, :utc_datetime_usec, null: false
    end

    create index(:task_claims, [:task_id, :claimed_at])
  end
end
