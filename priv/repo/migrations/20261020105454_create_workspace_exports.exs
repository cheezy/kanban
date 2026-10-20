defmodule Kanban.Repo.Migrations.CreateWorkspaceExports do
  @moduledoc """
  Tracks org-admin workspace exports (W2222).

  One row per requested export. `status` moves pending -> running ->
  succeeded | failed, and a succeeded export becomes expired once the
  scheduled cleanup deletes its file. `file_path` is the archive's location on
  the server, written only by the export worker and never taken from a client.

  `workspace_exports_one_active_index` allows at most one pending or running
  export per workspace, so a second request while one is in flight cannot
  queue a duplicate even when two requests race.
  """

  use Ecto.Migration

  def change do
    create table(:workspace_exports) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :requested_by_id, references(:users, on_delete: :nilify_all)
      add :status, :string, null: false, default: "pending"
      add :file_path, :string
      add :byte_size, :bigint
      add :expires_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_exports, [:workspace_id])
    create index(:workspace_exports, [:requested_by_id])
    create index(:workspace_exports, [:status, :expires_at])

    create unique_index(:workspace_exports, [:workspace_id],
             name: :workspace_exports_one_active_index,
             where: "status IN ('pending', 'running')"
           )

    create constraint(:workspace_exports, :workspace_exports_status_check,
             check: "status IN ('pending', 'running', 'succeeded', 'failed', 'expired')"
           )
  end
end
