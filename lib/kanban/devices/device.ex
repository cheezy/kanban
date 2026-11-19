defmodule Kanban.Devices.Device do
  @moduledoc """
  A phone or tablet a person has signed in to Stride on
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  The app supplies every field in `create_changeset/3` at sign-in; `user_id`
  comes from the caller's scope and is never cast. Afterwards it can change
  only its push token, push environment, locale, time zone and app version
  (`update_changeset/3`). `revoked_at` is set when
  the person, or reuse of an old refresh token, revokes the device, and
  `revoked_by_id` names the person who revoked it: `nil` when Stride revoked
  it, and cleared when the revoker's account is deleted. Revoking also clears
  `push_token`, so the same phone can sign in again as a new device.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.ChangesetText
  alias Kanban.Devices.ApprovalKey

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

  # What the app sends about itself at the token exchange; the client id
  # and the name come from the authorization code instead.
  @detail_fields [
    :platform,
    :device_class,
    :model,
    :os_version,
    :app_version,
    :locale,
    :time_zone,
    :approval_public_key
  ]

  @required_detail_fields [:platform, :device_class, :approval_public_key]

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
  # A BCP 47 language tag, or the platform form with underscores ("en_GB"):
  # a language subtag, then alphanumeric subtags.
  @locale_format ~r/\A[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*\z/

  @varchar_fields [:name, :model, :os_version, :app_version, :locale, :time_zone]

  # What the app may change about itself after sign-in.
  @update_fields [:push_token, :push_environment, :locale, :time_zone, :app_version]

  # push_token is a text column; APNs and FCM tokens are far shorter.
  @push_token_max 4096

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
    |> validate_time_zone()
    |> validate_format(:locale, @locale_format)
    |> validate_approval_public_key()
    |> unique_constraint(:push_token)
    |> check_constraint(:platform, name: :user_devices_platform)
    |> check_constraint(:device_class, name: :user_devices_device_class)
    |> check_constraint(:push_environment, name: :user_devices_push_environment)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  Checks the device details the app sends to `POST /oauth/token`, before the
  authorization code is redeemed, so a request with bad details leaves the
  code usable. Requires the platform, the device class and a P-256 approval
  public key (`Kanban.Devices.ApprovalKey`), and applies the same text and
  length rules as `create_changeset/3`.
  """
  @spec details_changeset(map()) :: Ecto.Changeset.t()
  def details_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @detail_fields)
    |> ChangesetText.validate_storable(@detail_fields -- [:platform, :device_class])
    |> validate_required(@required_detail_fields)
    |> validate_varchar_lengths()
    |> validate_time_zone()
    |> validate_format(:locale, @locale_format)
    |> validate_approval_public_key()
  end

  @doc """
  A changeset for what the app updates about the device it runs on
  (`PUT /api/me/devices/current`), at `now`: its push token and push
  environment, locale, time zone and app version. A key that is not sent is
  left as it is; an empty string clears the field, so `"push_token": ""`
  unregisters the device from pushes. The same text, length, locale and time
  zone rules as `create_changeset/3` apply, and a push token is unique among
  devices.
  """
  @spec update_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def update_changeset(device, attrs, now) do
    device
    |> cast(attrs, @update_fields)
    |> ChangesetText.validate_storable(@update_fields -- [:push_environment])
    |> validate_varchar_lengths()
    |> validate_length(:push_token, max: @push_token_max, count: :codepoints)
    |> validate_time_zone()
    |> validate_format(:locale, @locale_format)
    |> unique_constraint(:push_token)
    |> check_constraint(:push_environment, name: :user_devices_push_environment)
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

  # A key that is present must be a P-256 point in the wire format; it is
  # stored in its canonical spelling.
  defp validate_approval_public_key(changeset) do
    case fetch_change(changeset, :approval_public_key) do
      {:ok, key} when is_binary(key) -> put_canonical_key(changeset, ApprovalKey.canonical(key))
      _no_change -> changeset
    end
  end

  defp put_canonical_key(changeset, {:ok, key}),
    do: put_change(changeset, :approval_public_key, key)

  defp put_canonical_key(changeset, :error),
    do: add_error(changeset, :approval_public_key, "is not a P-256 public key")

  # A zone is stored only when the tz database knows it exactly as sent:
  # a padded, case-variant or invented zone would be read back as UTC.
  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        {:error, _reason} -> [time_zone: "is not a known time zone"]
      end
    end)
  end

  defp validate_varchar_lengths(changeset) do
    Enum.reduce(
      @varchar_fields,
      changeset,
      &validate_length(&2, &1, max: @varchar_max, count: :codepoints)
    )
  end
end
