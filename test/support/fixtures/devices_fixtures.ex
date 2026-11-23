defmodule Kanban.DevicesFixtures do
  @moduledoc """
  Test helpers for creating devices, their tokens and authorization codes via
  the `Kanban.Devices` context.
  """

  alias Kanban.Devices

  def valid_device_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      client_id: "stride-ios",
      platform: :ios,
      device_class: :phone,
      name: "Test iPhone",
      model: "iPhone15,2",
      os_version: "18.1",
      app_version: "1.0.0 (42)",
      locale: "en-US",
      time_zone: "Europe/London",
      push_token: nil,
      approval_public_key: valid_approval_public_key()
    })
  end

  @doc """
  A fresh P-256 public key in the wire format the token exchange takes: the
  uncompressed point, unpadded base64url.
  """
  def valid_approval_public_key do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    Base.url_encode64(public_key, padding: false)
  end

  @doc """
  A fresh P-256 approval key pair: `public_key` in the wire format a device
  registers (the uncompressed point, unpadded base64url) and `private_key`,
  the raw scalar, which `sign_approval/2` signs with as the app's key would.
  """
  def approval_keypair_fixture do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    %{public_key: Base.url_encode64(public_key, padding: false), private_key: private_key}
  end

  @doc """
  Signs `message` with `private_key` as the app does: ECDSA P-256 with
  SHA-256, a DER signature in unpadded base64url.
  """
  def sign_approval(private_key, message) do
    :ecdsa
    |> :crypto.sign(:sha256, message, [private_key, :secp256r1])
    |> Base.url_encode64(padding: false)
  end

  def device_fixture(scope, attrs \\ %{}, now \\ DateTime.utc_now()) do
    device_attrs = valid_device_attributes(attrs)
    {:ok, device} = Devices.create_device(scope, device_attrs, now)
    device
  end

  @doc "A device signed in at `now` and the token pair issued to it then."
  def device_with_tokens_fixture(scope, attrs \\ %{}, now \\ DateTime.utc_now()) do
    device = device_fixture(scope, attrs, now)
    {:ok, issued} = Devices.issue_tokens(device, now)
    {device, issued}
  end

  @doc "A fixed, non-secret PKCE verifier of the length RFC 7636 requires."
  def valid_code_verifier, do: "fixture-pkce-verifier-for-device-tests-0123456789"

  @doc "The PKCE S256 challenge for `valid_code_verifier/0`."
  def valid_code_challenge do
    :sha256
    |> :crypto.hash(valid_code_verifier())
    |> Base.url_encode64(padding: false)
  end

  def valid_authorization_code_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      client_id: "stride-ios",
      code_challenge: valid_code_challenge(),
      redirect_uri: "com.stridelikeaboss.app:/oauth/callback",
      device_name: "Test iPhone"
    })
  end

  def authorization_code_fixture(scope, attrs \\ %{}, now \\ DateTime.utc_now()) do
    code_attrs = valid_authorization_code_attributes(attrs)
    {:ok, code} = Devices.create_authorization_code(scope, code_attrs, now)
    code
  end

  @doc """
  Exchanges an `authorization_code_fixture/3` code for a new device at `now`,
  with the fixture's verifier, redirect URI and device details.
  """
  def redeem_authorization_code(code, now \\ DateTime.utc_now()) do
    grant = %{
      code: code.code,
      client_id: code.client_id,
      redirect_uri: code.redirect_uri,
      code_verifier: valid_code_verifier()
    }

    details = %{
      "platform" => "ios",
      "device_class" => "phone",
      "approval_public_key" => valid_approval_public_key()
    }

    Devices.exchange_authorization_code(grant, details, now)
  end
end
