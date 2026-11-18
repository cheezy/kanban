defmodule Kanban.Repo.Migrations.CreateDeviceTokens do
  @moduledoc """
  Creates `device_tokens`, the access and refresh tokens of a device
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  Only a token's SHA-256 hash is stored, unique across the table. `family_id`
  ties together every token issued since one sign-in, so reusing an old
  refresh token can revoke the whole family. Rows are deleted with their
  device, and so with its user.
  """
  use Ecto.Migration

  def change do
    create table(:device_tokens) do
      add :device_id, references(:user_devices, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :token_hash, :string, null: false
      add :family_id, :uuid, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_tokens, [:token_hash])
    create index(:device_tokens, [:device_id])
    create index(:device_tokens, [:family_id])

    create constraint(:device_tokens, :device_tokens_kind, check: "kind IN ('access', 'refresh')")
  end
end
