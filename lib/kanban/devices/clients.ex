defmodule Kanban.Devices.Clients do
  @moduledoc """
  The two OAuth clients a device signs in with, and the checks the authorize
  page makes on a sign-in request
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §9.1).

  Phase 1 has exactly two clients, `stride-ios` and `stride-android`
  (`Kanban.Devices.Device.client_ids/0`), configured in code rather than in a
  table. Both use one fixed redirect URI, the apps' private-use scheme
  `com.stridelikeaboss.app:/oauth/callback`. A request naming any other
  client or redirect URI is refused, and the only place a sign-in ever
  redirects to is `callback_uri/1`, built from that fixed URI: a redirect
  target never comes from a request.
  """

  alias Kanban.ChangesetText
  alias Kanban.Devices.AuthorizationCode
  alias Kanban.Devices.Device

  @redirect_scheme "com.stridelikeaboss.app"
  @redirect_uri "#{@redirect_scheme}:/oauth/callback"
  @device_classes ~w(phone tablet)
  # RFC 6749 Appendix A.5: state is one or more VSCHAR (printable ASCII).
  @state_format ~r/\A[\x20-\x7E]{1,255}\z/
  @max_device_name 255
  # Control characters (CR, LF, tab...) and the bidirectional overrides and
  # isolates could make the device name on the confirmation page read as
  # something else, and that name is what the person checks before Allow.
  @spoofing_characters ~r/[\p{Cc}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  # Checked in this order: the first field that fails names the reason.
  @request_checks [
    {"response_type", :unsupported_response_type},
    {"client_id", :invalid_client},
    {"redirect_uri", :invalid_redirect_uri},
    {"code_challenge_method", :invalid_code_challenge_method},
    {"code_challenge", :invalid_code_challenge},
    {"state", :invalid_state},
    {"device_name", :invalid_device_name},
    {"device_class", :invalid_device_class}
  ]
  @request_keys Enum.map(@request_checks, &elem(&1, 0))

  @typedoc "A sign-in request that passed `validate_authorize_request/1`."
  @type request :: %{
          client_id: String.t(),
          redirect_uri: String.t(),
          code_challenge: String.t(),
          state: String.t(),
          device_name: String.t(),
          device_class: String.t()
        }

  @typedoc "Why `validate_authorize_request/1` refused a request."
  @type reason ::
          :unsupported_response_type
          | :invalid_client
          | :invalid_redirect_uri
          | :invalid_code_challenge_method
          | :invalid_code_challenge
          | :invalid_state
          | :invalid_device_name
          | :invalid_device_class

  @doc "The client ids a device can sign in with."
  @spec client_ids() :: [String.t()]
  def client_ids, do: Device.client_ids()

  @doc "The one redirect URI both clients use."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @doc """
  The redirect URI's scheme as a CSP scheme source (`com.stridelikeaboss.app:`),
  so the authorize page's form may redirect to the app.
  """
  @spec redirect_scheme_source() :: String.t()
  def redirect_scheme_source, do: @redirect_scheme <> ":"

  @doc "The device classes the authorize page accepts as a hint."
  @spec device_classes() :: [String.t()]
  def device_classes, do: @device_classes

  @doc """
  Whether `client_id` is one of the two fixed clients and `redirect_uri` is
  exactly the fixed redirect URI. The comparison is exact: no trimming, case
  folding or normalising.
  """
  @spec valid?(term(), term()) :: boolean()
  def valid?(client_id, redirect_uri),
    do: valid_client?(client_id) and valid_redirect_uri?(redirect_uri)

  @doc "Whether `client_id` is one of the two fixed clients."
  @spec valid_client?(term()) :: boolean()
  def valid_client?(client_id) when is_binary(client_id), do: client_id in client_ids()
  def valid_client?(_client_id), do: false

  @doc "Whether `redirect_uri` is exactly the fixed redirect URI."
  @spec valid_redirect_uri?(term()) :: boolean()
  def valid_redirect_uri?(redirect_uri), do: redirect_uri === @redirect_uri

  @doc """
  Checks a sign-in request's parameters, as they arrive on
  `GET /oauth/authorize` and again on the confirm POST (whose hidden fields
  the browser could have changed).

  It requires a fixed client and the fixed redirect URI, PKCE with
  `code_challenge_method=S256` and a well-formed challenge, a `state`, and the
  `device_name` and `device_class` hints. `response_type` may be absent; when
  present it must be `code`. Every value must be a string, so a list or map
  parameter (`state[]=…`) is refused rather than crashing; a plain repeat
  (`state=a&state=b`) reaches this function as its last value, so callers
  check the raw query with `repeated_parameter?/1` first. A `device_name`
  with a control character or a bidirectional override is refused, so the
  name on the page reads as it was sent.
  """
  @spec validate_authorize_request(map()) :: {:ok, request()} | {:error, reason()}
  def validate_authorize_request(params) when is_map(params) do
    case Enum.find(@request_checks, fn {key, _reason} -> not valid_field?(key, params[key]) end) do
      nil -> {:ok, request(params)}
      {_key, reason} -> {:error, reason}
    end
  end

  defp request(params) do
    %{
      client_id: params["client_id"],
      redirect_uri: params["redirect_uri"],
      code_challenge: params["code_challenge"],
      state: params["state"],
      device_name: params["device_name"],
      device_class: params["device_class"]
    }
  end

  @doc """
  Whether the raw query string names any sign-in request parameter more than
  once, in any form (`state=a&state=b`, `state=a&state[]=b`). RFC 6749
  §4.1.2.1 treats such a request as invalid, where the parsed params would
  silently keep the last value. Plug has already refused a query it cannot
  decode before a controller sees it.
  """
  @spec repeated_parameter?(String.t()) :: boolean()
  def repeated_parameter?(query) when is_binary(query) do
    names =
      query
      |> URI.query_decoder()
      |> Enum.map(fn {key, _value} -> key |> String.split("[", parts: 2) |> hd() end)
      |> Enum.filter(&(&1 in @request_keys))

    length(names) != length(Enum.uniq(names))
  end

  @doc """
  The attributes `Kanban.Devices.create_authorization_code/3` takes for a
  validated request.
  """
  @spec code_attrs(request()) :: map()
  def code_attrs(request),
    do: Map.take(request, [:client_id, :code_challenge, :redirect_uri, :device_name])

  @doc """
  The fixed redirect URI with `params` as its query, percent-encoded per
  RFC 3986 (a space is `%20`, never `+`) in the order given, for example
  `[code: code, state: state]` or `[error: "access_denied", state: state]`.
  """
  @spec callback_uri(keyword(String.t())) :: String.t()
  def callback_uri(params) when is_list(params),
    do: @redirect_uri <> "?" <> URI.encode_query(params, :rfc3986)

  defp valid_field?("response_type", value), do: response_type?(value)
  defp valid_field?("client_id", value), do: valid_client?(value)
  defp valid_field?("redirect_uri", value), do: valid_redirect_uri?(value)
  defp valid_field?("code_challenge_method", value), do: value === "S256"
  defp valid_field?("code_challenge", value), do: AuthorizationCode.valid_code_challenge?(value)
  defp valid_field?("state", value), do: valid_state?(value)
  defp valid_field?("device_name", value), do: valid_device_name?(value)
  defp valid_field?("device_class", value), do: value in @device_classes

  defp response_type?(nil), do: true
  defp response_type?(response_type), do: response_type === "code"

  defp valid_state?(state) when is_binary(state), do: Regex.match?(@state_format, state)
  defp valid_state?(_state), do: false

  # The same rules AuthorizationCode.create_changeset/3 applies, so Allow
  # cannot fail on a name the page showed. Its length limit counts codepoints,
  # not graphemes, so this does too: a decomposed "é" is two.
  defp valid_device_name?(name) when is_binary(name) do
    ChangesetText.storable?(name) and ChangesetText.visible?(name) and
      not Regex.match?(@spoofing_characters, name) and
      length(String.codepoints(name)) <= @max_device_name
  end

  defp valid_device_name?(_name), do: false
end
