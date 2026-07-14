defmodule Kanban.Repo.Migrations.AddLastAgentNameToApiTokens do
  use Ecto.Migration

  # D137: remember the last usable agent_name a token presented on a claim,
  # complete, or create request, so later create requests carrying no agent
  # identity can still attribute created_by_agent. Nullable, display metadata
  # only — existing tokens keep nil. No index: the value is only read off the
  # already-loaded token row, never queried by.
  def change do
    alter table(:api_tokens) do
      add :last_agent_name, :string
    end
  end
end
