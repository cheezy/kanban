defmodule Kanban.Devices.AuthorizationCode do
  @moduledoc """
  A one-time OAuth authorization code
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8).

  Issued when a signed-in person allows a device to sign in, and traded once
  for the device's first tokens. It lives 60 seconds. Like a device token, the
  plain code (prefix `sdac_`) is shown once in the virtual `code` field and
  only its SHA-256 hash is stored. `code_challenge` is the PKCE S256
  challenge: 43 characters of unpadded URL-safe base64.

  `sso_organization_id` is the Organization whose single sign-on signed in
  the web session that allowed the sign-in, when the web two-factor gate
  would exempt that session, and `nil` otherwise
  (`Kanban.Devices.SsoExemption`). It is set from the server's session,
  never cast from a parameter, and the code exchange copies it onto the
  device.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.ChangesetText
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Organizations.Organization

  @lifetime_seconds 60
  @prefix "sdac"
  @fields [:client_id, :code_challenge, :redirect_uri, :device_name]
  @code_challenge_format ~r/\A[A-Za-z0-9_-]{43}\z/

  @type t :: %__MODULE__{}

  schema "oauth_authorization_codes" do
    field :client_id, :string
    field :code_hash, :string, redact: true
    field :code, :string, virtual: true, redact: true
    field :code_challenge, :string
    field :redirect_uri, :string
    field :device_name, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, User
    belongs_to :sso_organization, Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Whether `challenge` has the shape of a PKCE S256 challenge: 43 characters of
  unpadded URL-safe base64. The authorize page checks it before showing the
  confirmation, so Allow cannot fail on a challenge the page accepted.
  """
  @spec valid_code_challenge?(term()) :: boolean()
  def valid_code_challenge?(challenge) when is_binary(challenge),
    do: Regex.match?(@code_challenge_format, challenge)

  def valid_code_challenge?(_challenge), do: false

  @doc """
  A changeset for a new code for `user_id`, issued at `now` and expiring
  #{@lifetime_seconds} seconds later, with a fresh plain value in `code` and
  its hash in `code_hash`.
  """
  @spec create_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(code, attrs, now) do
    plain = DeviceToken.generate(@prefix)
    code_hash = DeviceToken.hash_token(plain)
    client_ids = Device.client_ids()
    expires_at = DateTime.add(now, @lifetime_seconds, :second)

    code
    |> cast(attrs, @fields)
    |> ChangesetText.validate_storable(@fields)
    |> validate_required(@fields)
    |> ChangesetText.validate_visible([:device_name])
    |> validate_inclusion(:client_id, client_ids)
    |> validate_format(:code_challenge, @code_challenge_format)
    |> validate_length(:device_name, max: 255, count: :codepoints)
    |> validate_length(:redirect_uri, max: 255, count: :codepoints)
    |> put_change(:code, plain)
    |> put_change(:code_hash, code_hash)
    |> put_change(:expires_at, expires_at)
    |> put_change(:inserted_at, now)
    |> unique_constraint(:code_hash)
  end
end
