defmodule Kanban.Devices.Nonce do
  @moduledoc """
  A single-use key a device sent (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.5, §8), in `device_nonces`.

  An `:idempotency` row is the first successful result of an app review
  decision sent with an `Idempotency-Key` header: the HTTP status and the
  JSON body the device was sent, kept until `expires_at` (24 hours) so a
  retried request with the same key gets the same answer. A `:socket_token`
  row is the id of a socket token the app connected `/api/socket` with, kept
  until just after the token expires so it can never connect twice; it has
  no response.

  Only `key_hash` is stored: a SHA-256 hash of the key together with the
  action and the task it was sent for, or of the socket token id
  (`Kanban.Devices.Nonces`), so a key is never compared, logged or stored in
  plain text. Rows are unique on
  `(device_id, kind, key_hash)` and are written only through
  `Kanban.Devices.Nonces`, so the schema has no changeset.
  """
  use Ecto.Schema

  alias Kanban.Devices.Device

  @type kind :: :idempotency | :socket_token
  @type t :: %__MODULE__{}

  schema "device_nonces" do
    field :kind, Ecto.Enum, values: [:idempotency, :socket_token]
    field :key_hash, :string, redact: true
    field :response_status, :integer
    field :response_body, :map
    field :expires_at, :utc_datetime

    belongs_to :device, Device

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
