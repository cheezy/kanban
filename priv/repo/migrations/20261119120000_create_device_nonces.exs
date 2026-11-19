defmodule Kanban.Repo.Migrations.CreateDeviceNonces do
  @moduledoc """
  Creates `device_nonces`, the single-use keys a device sends
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.5, §8).

  An `idempotency` row holds the first successful result of an app review
  decision sent with an `Idempotency-Key` header, so a retried request with
  the same key replays it for 24 hours instead of answering 409. Only a
  SHA-256 hash of the key is stored, scoped to the device by the unique index
  on `(device_id, kind, key_hash)`; that index is also what makes two
  parallel requests with one key run the action once. `socket_token` is
  reserved for the app's socket tokens. Rows are deleted with their device,
  and `Kanban.Devices.NonceSweepWorker` deletes expired rows hourly.
  """
  use Ecto.Migration

  def change do
    create table(:device_nonces) do
      add :device_id, references(:user_devices, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :key_hash, :string, null: false
      add :response_status, :integer
      add :response_body, :map
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_nonces, [:device_id, :kind, :key_hash])
    create index(:device_nonces, [:expires_at])

    create constraint(:device_nonces, :device_nonces_kind,
             check: "kind IN ('idempotency', 'socket_token')"
           )
  end
end
