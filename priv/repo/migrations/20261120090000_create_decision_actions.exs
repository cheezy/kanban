defmodule Kanban.Repo.Migrations.CreateDecisionActions do
  @moduledoc """
  Creates `decision_actions`, one row per decision a person has first acted
  on (`Kanban.Decisions.ActedOn`): the decision's id, such as
  `"review:task:12"`, and the moment it started waiting.

  A decision is built afresh on every read and has no row of its own
  (`Kanban.Decisions`), so nothing else can say whether one was already acted
  on. A reply resolves nothing, and two people can act on one decision at
  the same moment; the unique index on `(decision_key, since)` lets exactly
  one of those actions record it, and only that one emits
  `[:kanban, :decision, :acted_on]`. A decision that comes back later starts
  waiting at a new moment, so it is a new row.

  No user is stored, so an account deletion leaves nothing behind here. Rows
  are deleted with their board, and with their task when they have one.
  """
  use Ecto.Migration

  def change do
    create table(:decision_actions) do
      add :decision_key, :string, null: false
      add :since, :utc_datetime_usec, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:decision_actions, [:decision_key, :since])
    create index(:decision_actions, [:board_id])
    create index(:decision_actions, [:task_id])
  end
end
