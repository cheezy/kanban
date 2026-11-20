defmodule Kanban.Repo.Migrations.AddCreatedViaToTasks do
  @moduledoc """
  Adds `tasks.created_via`, how a task was created outside the web form and
  the agent API (W2760, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §8).
  A task captured in the app (`POST /api/me/tasks`) stores `"mobile"`; every
  other task keeps `NULL`, so existing rows need no backfill.

  There is no draft flag (design decision 6): a captured task is an ordinary
  Backlog task, and whoever moves it to Ready decides when it is ready.
  """
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :created_via, :string
    end
  end
end
