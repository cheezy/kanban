defmodule Kanban.Repo.Migrations.AddExpiresAtToApiTokens do
  use Ecto.Migration

  # D107: give API tokens a bounded lifetime. Nullable for back-compat — existing
  # tokens (expires_at IS NULL) keep authenticating; only newly-issued tokens get
  # a default expiry.
  def change do
    alter table(:api_tokens) do
      add :expires_at, :utc_datetime
    end
  end
end
