defmodule Kanban.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :agent_capabilities, {:array, :string}, default: []
      add :agent_model, :string
      add :agent_version, :string
      add :agent_purpose, :text
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_tokens, [:user_id])
    create unique_index(:api_tokens, [:token_hash])
  end
end
