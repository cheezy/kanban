defmodule Kanban.Repo.Migrations.AddReplacedByIdToUsersTokens do
  use Ecto.Migration

  # D425: a reissued session token points at the token that replaced it, so a
  # replay of the replaced token is handed that successor instead of minting a
  # new one, and revoking the successor (sign-out) deletes the token it
  # replaced through the cascade.
  def change do
    alter table(:users_tokens) do
      add :replaced_by_id, references(:users_tokens, on_delete: :delete_all)
    end

    create index(:users_tokens, [:replaced_by_id])
  end
end
