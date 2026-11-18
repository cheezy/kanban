defmodule Kanban.Devices.Device do
  @moduledoc """
  A phone or tablet a person has signed in to Stride on
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  The app supplies every field in `create_changeset/3` at sign-in; `user_id`
  comes from the caller's scope and is never cast. `revoked_at` is set when
  the person, or reuse of an old refresh token, revokes the device, and
  `revoked_by_id` names the person who revoked it: `nil` when Stride revoked
  it, and cleared when the revoker's account is deleted. Revoking also clears
  `push_token`, so the same phone can sign in again as a new device.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.ChangesetText

  @client_ids ~w(stride-ios stride-android)

  @cast_fields [
    :client_id,
    :platform,
    :device_class,
    :name,
    :model,
    :os_version,
    :app_version,
    :locale,
    :time_zone,
    :push_token,
    :push_environment,
    :approval_public_key
  ]

  @required_fields [:client_id, :platform, :device_class, :name]

  @text_fields [
    :client_id,
    :name,
    :model,
    :os_version,
    :app_version,
    :locale,
    :time_zone,
    :push_token,
    :approval_public_key
  ]

  # varchar(255) columns. Postgres counts code points, so the checks do too.
  @varchar_max 255
  @varchar_fields [:name, :model, :os_version, :app_version, :locale, :time_zone]

  @type t :: %__MODULE__{}

  schema "user_devices" do
    field :client_id, :string
    field :platform, Ecto.Enum, values: [:ios, :android]
    field :device_class, Ecto.Enum, values: [:phone, :tablet]
    field :name, :string
    field :model, :string
    field :os_version, :string
    field :app_version, :string
    field :locale, :string
    field :time_zone, :string
    field :push_token, :string, redact: true
    field :push_environment, Ecto.Enum, values: [:sandbox, :production]
    field :approval_public_key, :string
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User
    belongs_to :revoked_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The OAuth client ids a device can sign in with. Phase 1 has exactly two,
  configured in code rather than in a table.
  """
  @spec client_ids() :: [String.t()]
  def client_ids, do: @client_ids

  @doc """
  A changeset for a new device signed in at `now`, which becomes its
  `inserted_at`: the anchor of its refresh tokens' 90-day limit.
  """
  @spec create_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(device, attrs, now) do
    device
    |> cast(attrs, @cast_fields)
    |> ChangesetText.validate_storable(@text_fields)
    |> validate_required(@required_fields)
    |> ChangesetText.validate_visible([:name])
    |> validate_inclusion(:client_id, @client_ids)
    |> validate_varchar_lengths()
    |> unique_constraint(:push_token)
    |> check_constraint(:platform, name: :user_devices_platform)
    |> check_constraint(:device_class, name: :user_devices_device_class)
    |> check_constraint(:push_environment, name: :user_devices_push_environment)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  A changeset that revokes the device at `now`, by `revoked_by_id` (`nil`
  when Stride revokes it). It clears `push_token`, which is unique among
  devices, so a phone keeps the same token across sign-ins.
  """
  @spec revoke_changeset(t(), integer() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(device, revoked_by_id, now) do
    change(device,
      revoked_at: now,
      revoked_by_id: revoked_by_id,
      push_token: nil,
      updated_at: now
    )
  end

  @doc "Returns true once the device has been revoked."
  @spec revoked?(t()) :: boolean()
  def revoked?(%__MODULE__{revoked_at: revoked_at}), do: not is_nil(revoked_at)

  defp validate_varchar_lengths(changeset) do
    Enum.reduce(
      @varchar_fields,
      changeset,
      &validate_length(&2, &1, max: @varchar_max, count: :codepoints)
    )
  end
end
