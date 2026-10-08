defmodule Kanban.Repo.Migrations.CreateUserTotps do
  @moduledoc """
  One TOTP two-factor record per user (W2241).

  `secret` holds AES-256-GCM ciphertext written by
  `Kanban.Encryption.EncryptedBinary`, never the raw secret. Two-factor is
  enabled only once `confirmed_at` is set; until then the row is an
  enrollment in progress. `last_used_step` is the 30-second TOTP step of the
  last accepted code, so the same code cannot be used twice.
  `recovery_code_hashes` holds keyed HMAC-SHA256 digests of the unused
  recovery codes.
  """

  use Ecto.Migration

  def change do
    create table(:user_totps) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :secret, :binary, null: false
      add :confirmed_at, :utc_datetime
      add :last_used_step, :bigint
      add :recovery_code_hashes, {:array, :binary}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_totps, [:user_id])
  end
end
