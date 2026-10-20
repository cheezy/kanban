defmodule Kanban.Repo.Migrations.AddWorkspaceToApiTokens do
  @moduledoc """
  Workspace-scoped API tokens (W2220).

  An API token now belongs to exactly one of a board or a workspace:
  `board_id` becomes nullable, `workspace_id` is added, and the
  `api_tokens_board_xor_workspace` check constraint rejects a row with both or
  neither. Every existing row has a board and no workspace, so it already
  satisfies the constraint and nothing is backfilled.
  """

  use Ecto.Migration

  def up do
    alter table(:api_tokens) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      modify :board_id, :bigint, null: true
    end

    create index(:api_tokens, [:workspace_id])

    create constraint(:api_tokens, :api_tokens_board_xor_workspace,
             check: "(board_id IS NULL) <> (workspace_id IS NULL)"
           )
  end

  def down do
    drop constraint(:api_tokens, :api_tokens_board_xor_workspace)

    # A workspace token has no board, so it cannot survive board_id becoming
    # NOT NULL again.
    execute "DELETE FROM api_tokens WHERE board_id IS NULL"

    drop index(:api_tokens, [:workspace_id])

    alter table(:api_tokens) do
      remove :workspace_id
      modify :board_id, :bigint, null: false
    end
  end
end
