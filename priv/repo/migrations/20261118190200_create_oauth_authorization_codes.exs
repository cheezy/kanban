defmodule Kanban.Repo.Migrations.CreateOauthAuthorizationCodes do
  @moduledoc """
  Creates `oauth_authorization_codes`, the one-time codes a device trades for
  its first tokens (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  Only a code's SHA-256 hash is stored, unique across the table. A code lives
  60 seconds and is used once. Rows are deleted with their user.
  """
  use Ecto.Migration

  def change do
    create table(:oauth_authorization_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, :string, null: false
      add :code_hash, :string, null: false
      add :code_challenge, :string, null: false
      add :redirect_uri, :string, null: false
      add :device_name, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])
    create index(:oauth_authorization_codes, [:user_id])
  end
end
