defmodule Kanban.Devices.DeviceToken do
  @moduledoc """
  An access or refresh token of a `Kanban.Devices.Device`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  A token is 32 random bytes from `:crypto.strong_rand_bytes/1`, shown once:
  the plain value lives only in the virtual `token` field of the struct
  `new_changeset/2` returns, and the table stores its SHA-256 hash. The plain
  value is looked up by hashing it again, so it is never compared, logged or
  stored.

  The prefixes `sdat_` (access) and `sdrt_` (refresh) tell the two kinds
  apart, and apart from agent API tokens, which start `stride_`.

  `family_id` is shared by every token issued since one sign-in. The table
  has no `revoked_at`: a token is revoked by setting `expires_at` to the
  moment of revocation, and a refresh token is used up by setting `used_at`.
  Used rows are kept, so presenting one again is detected as reuse.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Devices.Device

  @prefixes %{access: "sdat", refresh: "sdrt"}

  @type t :: %__MODULE__{}

  schema "device_tokens" do
    field :kind, Ecto.Enum, values: [:access, :refresh]
    field :token_hash, :string, redact: true
    field :token, :string, virtual: true, redact: true
    field :family_id, Ecto.UUID
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :device, Device

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  A changeset for a new token of `device`, with a freshly generated plain
  value in `token` and its hash in `token_hash`. `attrs` holds `:kind`,
  `:family_id`, `:expires_at` and `:inserted_at`, all set by
  `Kanban.Devices`, never by a client.
  """
  @spec new_changeset(Device.t(), map()) :: Ecto.Changeset.t()
  def new_changeset(%Device{id: device_id}, %{kind: kind} = attrs) do
    prefix = Map.fetch!(@prefixes, kind)
    token = generate(prefix)
    token_hash = hash_token(token)
    changes = Map.take(attrs, [:kind, :family_id, :expires_at, :inserted_at])

    %__MODULE__{device_id: device_id}
    |> change(changes)
    |> put_change(:token, token)
    |> put_change(:token_hash, token_hash)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Hashes a plain token, code or nonce for storage and lookup: SHA-256 as
  lowercase hex, as agent API tokens do.
  """
  @spec hash_token(binary()) :: String.t()
  def hash_token(token) when is_binary(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Generates a plain secret: `prefix`, an underscore and 32 random bytes in
  unpadded URL-safe base64.
  """
  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    random =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    prefix <> "_" <> random
  end
end
