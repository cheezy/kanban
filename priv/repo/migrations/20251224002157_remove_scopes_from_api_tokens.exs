defmodule Kanban.Repo.Migrations.RemoveScopesFromApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      remove :scopes
    end
  end
end
