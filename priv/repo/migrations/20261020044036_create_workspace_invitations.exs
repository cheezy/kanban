defmodule Kanban.Repo.Migrations.CreateWorkspaceInvitations do
  @moduledoc """
  Email invitations to an Organization workspace or to a free board (W2219).

  An invitation is either a workspace invitation (`role` set, on an org
  workspace, optionally with a board grant) or a board-only invitation (`role`
  null, on the inviting owner's personal workspace, with a board grant). The
  database enforces the shape:

    * `workspace_invitations_grant_present` — every invitation carries a role,
      a board grant, or both. It checks `board_access` rather than `board_id`,
      so deleting a board (which nilifies `board_id`) never violates it; a
      board-only invitation whose board is gone is refused at acceptance.
    * `workspace_invitations_board_has_access` — a board always comes with an
      access level.
    * `workspace_invitations_one_pending_index` — at most one pending
      invitation per workspace, email and board. Rows whose board was deleted
      leave the index, so a nilified board never collides with a
      workspace-only invitation.

  Only a SHA-256 hash of the token is stored (`token_hash`); the plaintext
  appears only in the email. `email` is citext, like `users.email`.
  `registered_user_id` links an invitation to the account registered from its
  link, so it is accepted once that account confirms its email, in whatever
  browser the confirmation link is opened.
  """

  use Ecto.Migration

  def change do
    create table(:workspace_invitations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :role, :string
      add :board_id, references(:boards, on_delete: :nilify_all)
      add :board_access, :string
      add :token_hash, :binary, null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :registered_user_id, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_invitations, [:token_hash])

    create unique_index(
             :workspace_invitations,
             [:workspace_id, :email, "COALESCE(board_id, 0)"],
             name: :workspace_invitations_one_pending_index,
             where:
               "accepted_at IS NULL AND revoked_at IS NULL AND (board_id IS NOT NULL OR board_access IS NULL)"
           )

    create index(:workspace_invitations, [:workspace_id])
    create index(:workspace_invitations, [:board_id])
    create index(:workspace_invitations, [:invited_by_id])
    create index(:workspace_invitations, [:registered_user_id])

    create constraint(:workspace_invitations, :workspace_invitations_grant_present,
             check: "role IS NOT NULL OR board_access IS NOT NULL"
           )

    create constraint(:workspace_invitations, :workspace_invitations_role_check,
             check: "role IS NULL OR role IN ('member', 'guest')"
           )

    create constraint(:workspace_invitations, :workspace_invitations_access_check,
             check: "board_access IS NULL OR board_access IN ('read_only', 'modify')"
           )

    create constraint(:workspace_invitations, :workspace_invitations_board_has_access,
             check: "board_id IS NULL OR board_access IS NOT NULL"
           )
  end
end
