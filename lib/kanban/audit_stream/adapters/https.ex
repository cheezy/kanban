defmodule Kanban.AuditStream.Adapters.Https do
  @moduledoc """
  The adapter for a generic HTTPS endpoint
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §5.3).

  ## Settings

    * `format`: `"json"` (the default) sends one JSON batch,
      `{"version":1,"batch_id","destination_id","organization","events"}`;
      `"ndjson"` sends one event per line, each line ending in a newline.
    * `header_name`: an optional header sent with the destination's
      `credential` as its value, such as `Authorization` or `X-goog-api-key`.
      It must be an HTTP token, and the names Stride sets
      (`reserved_headers/0`) are refused in any case, so an org-admin cannot
      spoof Stride's own headers to a receiver. Connection and framing
      names (`framing_headers/0`) are refused too, since they would change
      how the request is sent. The name and the credential come together,
      and the credential must be a sendable header value: visible ASCII,
      space and tab (`validate_credential/2`).

  ## Request

  The body is gzipped here (`Kanban.Webhooks.Transport` does not compress),
  with `Content-Encoding: gzip`. Both signatures cover the **decompressed**
  body and share one timestamp `t`:

    * `X-Stride-Signature` is the webhook format, `t=<t>,v1=<hex HMAC>`,
      made by `Kanban.Webhooks.Signer.sign_all/3`. While
      `previous_secret_expires_at` is later than `t`, it carries one `v1` per
      secret, the old one first; from that moment on, only the current one.
    * `X-Stride-Audit-Signature` is `t=<t>,kid=<key id>,ed25519=<signature>`,
      the instance's Ed25519 signature (`Kanban.AuditLog.Signing`) over
      `"<t>.<destination id>.<body>"`, as base64url without padding. It is
      left out when the instance has no signing key.

  Headers are lowercase, and the custom header comes last. Its name and
  value are checked again here, so a row that never went through the
  changeset still cannot replace a Stride header, and a value the transport
  would refuse is left out rather than quoted in a transport error. Nothing here logs a secret, a signature or a
  header value.
  """

  @behaviour Kanban.AuditStream.Adapter

  alias Kanban.AuditLog.Signing
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Payload
  alias Kanban.Webhooks.Signer

  @formats ~w(json ndjson)

  @reserved_headers ~w(
    content-type content-encoding content-length host user-agent
    x-stride-signature x-stride-audit-signature x-stride-batch
    x-stride-event-count x-stride-destination
  )

  # Connection and framing headers decide how the request is sent, not what
  # it says; a server refuses a request whose framing they contradict.
  @framing_headers ~w(connection keep-alive proxy-connection te trailer transfer-encoding upgrade expect)

  # An HTTP field name is a token (RFC 9110 §5.6.2).
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,256}\z/

  @content_types %{"json" => "application/json", "ndjson" => "application/x-ndjson"}

  @doc "The header names Stride sets, lowercase; a custom header may not use one."
  @spec reserved_headers() :: [String.t()]
  def reserved_headers, do: @reserved_headers

  @doc """
  The connection and framing header names, lowercase, which a custom header
  may not use either.
  """
  @spec framing_headers() :: [String.t()]
  def framing_headers, do: @framing_headers

  @impl true
  def validate(settings) when is_map(settings) do
    [
      format_error(Map.get(settings, "format")),
      header_name_error(Map.get(settings, "header_name"))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :ok
      reasons -> {:error, Enum.map(reasons, &{:settings, {"is invalid", validation: &1}})}
    end
  end

  defp format_error(nil), do: nil
  defp format_error(format) when format in @formats, do: nil
  defp format_error(_format), do: :format

  # nil when the name is absent or usable, else why it is refused.
  defp header_name_error(name) when name in [nil, ""], do: nil
  defp header_name_error(name) when not is_binary(name), do: :header_name

  defp header_name_error(name) do
    cond do
      not Regex.match?(@token, name) -> :header_name
      reserved_header?(name) -> :reserved_header
      true -> nil
    end
  end

  defp reserved_header?(name),
    do: String.downcase(name) in @reserved_headers or String.downcase(name) in @framing_headers

  @doc """
  An HTTPS endpoint has no URL rules of its own beyond the
  `Kanban.Webhooks.UrlGuard` checks every destination gets.
  """
  @impl true
  def validate_url(_url), do: :ok

  @impl true
  def validate_credential(credential, settings) when is_map(settings) do
    case credential_error(credential, header_name?(Map.get(settings, "header_name"))) do
      nil -> :ok
      error -> {:error, [error]}
    end
  end

  defp credential_error(credential, named?) do
    present? = is_binary(credential) and credential != ""

    cond do
      present? and not header_value?(credential) ->
        {:credential, {"is invalid", validation: :header_value}}

      named? and not present? ->
        {:credential, {"can't be blank", validation: :required}}

      present? and not named? ->
        {:settings, {"is invalid", validation: :header_name_required}}

      true ->
        nil
    end
  end

  defp header_name?(name), do: is_binary(name) and name != ""

  # What an HTTP/1.1 client sends as a field value: visible ASCII, space and
  # horizontal tab (Mint refuses anything else and quotes the whole value in
  # its error, so a credential outside this set must never reach it).
  defp header_value?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 32..126 or &1 == ?\t))
  end

  @impl true
  def build_request(%Destination{} = destination, batch) do
    batch = Map.put_new_lazy(batch, :signed_at, fn -> System.system_time(:second) end)
    {url, secrets} = readable!(destination, batch)
    format = format(destination.settings)
    body = encode(format, destination, batch)

    {url, headers(destination, batch, format, body, secrets), :zlib.gzip(body)}
  end

  defp headers(destination, batch, format, body, secrets) do
    [
      {"content-type", Map.fetch!(@content_types, format)},
      {"content-encoding", "gzip"},
      {"user-agent", "Stride-AuditStream/1"},
      {"x-stride-destination", Integer.to_string(destination.id)},
      {"x-stride-batch", batch.batch_id},
      {"x-stride-event-count", batch.events |> length() |> Integer.to_string()},
      {"x-stride-signature", Signer.sign_all(body, secrets, batch.signed_at)}
    ] ++ audit_signature(destination, batch.signed_at, body) ++ custom_header(destination)
  end

  # The URL and the current signing secret are needed to send at all; the
  # worker halts a destination whose secrets are unreadable before it gets
  # here, so a missing one is a caller error, raised without the value.
  defp readable!(%Destination{url: url, signing_secret: secret} = destination, batch)
       when is_binary(url) and is_binary(secret) do
    {url, rotation_secrets(destination, secret, batch.signed_at)}
  end

  defp readable!(_destination, _batch) do
    raise ArgumentError, "an HTTPS destination needs a readable URL and signing secret"
  end

  defp rotation_secrets(
         %Destination{previous_signing_secret: previous, previous_secret_expires_at: expires_at},
         current,
         signed_at
       )
       when is_binary(previous) and is_struct(expires_at, DateTime) do
    if DateTime.to_unix(expires_at) > signed_at, do: [previous, current], else: [current]
  end

  defp rotation_secrets(_destination, current, _signed_at), do: [current]

  defp format(%{"format" => format}) when format in @formats, do: format
  defp format(_settings), do: "json"

  defp encode("json", destination, batch) do
    Jason.encode!(%{
      "version" => 1,
      "batch_id" => batch.batch_id,
      "destination_id" => destination.id,
      "organization" => Payload.organization(batch.organization),
      "events" => batch.events
    })
  end

  defp encode("ndjson", _destination, batch) do
    Enum.map_join(batch.events, &(Jason.encode!(&1) <> "\n"))
  end

  defp audit_signature(destination, signed_at, body) do
    t = Integer.to_string(signed_at)

    case Signing.sign([t, ".", Integer.to_string(destination.id), ".", body]) do
      {:ok, %{signature: signature, key_id: key_id}} ->
        encoded = Base.url_encode64(signature, padding: false)
        [{"x-stride-audit-signature", "t=#{t},kid=#{key_id},ed25519=#{encoded}"}]

      {:error, :not_configured} ->
        []
    end
  end

  defp custom_header(%Destination{settings: settings, credential: credential}) do
    name = (settings || %{})["header_name"]

    if sendable_header?(name, credential),
      do: [{String.downcase(name), credential}],
      else: []
  end

  defp sendable_header?(name, credential)
       when is_binary(name) and name != "" and is_binary(credential) and credential != "",
       do: header_name_error(name) == nil and header_value?(credential)

  defp sendable_header?(_name, _credential), do: false

  @impl true
  def classify(status, _body) when status in 200..299, do: :ok
  def classify(status, _body) when status in [408, 429], do: {:retry, nil}
  def classify(status, _body) when status in 500..599, do: {:retry, nil}
  def classify(413, _body), do: :split
  def classify(status, _body) when status in [401, 403], do: :unauthorized
  def classify(_status, _body), do: :permanent

  @impl true
  def max_event_age, do: :infinity
end
