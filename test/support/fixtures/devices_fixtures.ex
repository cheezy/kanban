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
      approval_public_key: "fixture-public-key"
    })
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

  @doc "A PKCE S256 challenge for a fixed, non-secret fixture verifier."
  def valid_code_challenge do
    :sha256
    |> :crypto.hash("fixture-pkce-verifier-for-device-tests")
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
end
