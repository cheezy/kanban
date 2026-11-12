defmodule Kanban.AuditStream.Adapters.SplunkHec do
  @moduledoc """
  The adapter for a Splunk HTTP Event Collector
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §5.1).

  ## Settings

    * `index`: optional. Left out of every event when blank, so the token's
      default index applies. When set it must be a Splunk index name:
      lowercase letters, digits, `_` and `-`, not starting with `-`.
    * `source_type`: optional, `stride:audit` when blank.

  The destination's `credential` is the HEC token, sent only as
  `Authorization: Splunk <token>`. `validate_credential/2` refuses a token
  the transport could not send as a header value, so it is never quoted in
  a transport error.

  ## The URL

  The behaviour's `validate/1` sees the settings only, because the URL is a
  secret field of its own, so the URL rules are the optional
  `validate_url/1`, which `Kanban.AuditStream.Destination` calls whenever
  the URL changes: HTTPS, a path of exactly `/services/collector` or
  `/services/collector/event`, and no query string. `url_warning/1` is for
  the destination form to show: a Splunk Cloud host without `http-inputs`
  is probably the web address, not the collector.

  ## Request

  `POST` with `Content-Type: application/json`, `Content-Encoding: gzip`
  (the body is gzipped here) and `User-Agent: Stride-AuditStream/1`. The body
  is the HEC batch format: one HEC event object per event, newline
  separated, each `{"time", "host", "source", "sourcetype", "index", "event"}`
  with `time` the event's `occurred_at` in epoch seconds with milliseconds,
  `host` its `instance`, and `event` the `Kanban.AuditStream.Payload` event.

  Indexer acknowledgement is not used, and no `X-Splunk-Request-Channel`
  header is ever sent.

  ## Responses

  `classify/2` reads the numeric `code` in Splunk's body as well as the
  status, because several configuration faults come back as HTTP 400. A
  wrong index or indexer acknowledgement is a `{:config_error, reason}`
  rather than a rejected batch, so it cannot be skipped batch by batch: an
  org-admin cannot make Splunk refuse every batch and then skip them one by
  one, leaving the SIEM silently without events (§12.3).
  `fix_message/2` gives the translated fix for each reason.

  Nothing here logs or returns the token or Splunk's body text.
  """

  @behaviour Kanban.AuditStream.Adapter

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.AuditStream.Destination
  alias Kanban.Webhooks.UrlGuard

  require Logger

  @paths ["/services/collector", "/services/collector/event"]
  @cloud_domains [".splunkcloud.com", ".splunkcloudgc.com"]
  @default_source_type "stride:audit"

  @index ~r/\A[a-z0-9_][a-z0-9_-]*\z/

  @bad_data_codes [5, 6, 12, 13, 15]
  @unauthorized_codes [21, 22]
  @accepted_warning_codes [24, 25]

  @english_fixes %{
    incorrect_index: "the token can't write to the index",
    indexer_ack_enabled: "turn off indexer acknowledgement on this HEC token",
    ack_disabled: "Stride does not use indexer acknowledgement; check the HEC URL",
    query_string_auth: "remove the token from the HEC URL"
  }

  # The most bytes a gzipped answer is inflated to: Kanban.Webhooks.Transport
  # keeps at most this much of a body, and a code is a few bytes.
  @max_inflated 65_536

  @config_errors %{
    7 => :incorrect_index,
    10 => :indexer_ack_enabled,
    11 => :indexer_ack_enabled,
    14 => :ack_disabled,
    16 => :query_string_auth
  }

  @impl true
  def validate(settings) when is_map(settings) do
    case index_error(Map.get(settings, "index")) do
      nil -> :ok
      reason -> {:error, [settings: {"is invalid", validation: reason}]}
    end
  end

  defp index_error(index) when index in [nil, ""], do: nil
  defp index_error(index) when is_binary(index), do: if(index?(index), do: nil, else: :index)
  defp index_error(_index), do: :index

  defp index?(index), do: byte_size(index) <= 80 and Regex.match?(@index, index)

  @impl true
  @doc """
  Checks a HEC URL: an HTTPS URL `Kanban.Webhooks.UrlGuard.validate_syntax/2`
  accepts, whose path is exactly `/services/collector` or
  `/services/collector/event` and which has no query string. Anything else
  is refused, `/services/collector/raw` among them, since it would index
  each line as raw text. Errors are `Ecto.Changeset` errors on `:url`.
  """
  def validate_url(url) do
    case url_error(url) do
      nil -> :ok
      reason -> {:error, [url: {"is invalid", validation: reason}]}
    end
  end

  defp url_error(url) when is_binary(url) do
    case UrlGuard.validate_syntax(url, allow_http: false) do
      :ok -> url |> URI.parse() |> collector_error()
      {:error, reason} -> reason
    end
  end

  defp url_error(_url), do: :invalid_url

  defp collector_error(%URI{query: query}) when is_binary(query), do: :query
  defp collector_error(%URI{path: path, fragment: nil}) when path in @paths, do: nil
  defp collector_error(%URI{}), do: :path

  @doc """
  A translated warning for a HEC URL whose host is in Splunk Cloud
  (`*.splunkcloud.com` or `*.splunkcloudgc.com`) but does not start with
  `http-inputs`, so it is probably the web address rather than the
  collector; nil for any other URL. A warning, not an error: the URL can
  still be saved.
  """
  @spec url_warning(term()) :: String.t() | nil
  def url_warning(url) when is_binary(url) do
    if web_address?(URI.parse(url).host) do
      gettext(
        "This looks like the Splunk Cloud web address. The collector address starts with http-inputs."
      )
    end
  end

  def url_warning(_url), do: nil

  defp web_address?(host) when is_binary(host) do
    host = String.downcase(host)

    Enum.any?(@cloud_domains, &String.ends_with?(host, &1)) and
      not String.starts_with?(host, "http-inputs")
  end

  defp web_address?(_host), do: false

  @impl true
  def validate_credential(credential, _settings) do
    if is_binary(credential) and credential != "" and not token?(credential),
      do: {:error, [credential: {"is invalid", validation: :header_value}]},
      else: :ok
  end

  # A HEC token is one header word: visible ASCII with no space, so
  # "Splunk <token>" is a value the transport sends rather than refuses
  # (Mint quotes a refused value in its error).
  defp token?(token), do: token |> :binary.bin_to_list() |> Enum.all?(&(&1 in 33..126))

  @impl true
  def build_request(%Destination{url: url} = destination, batch) when is_binary(url) do
    settings = destination.settings || %{}
    body = Enum.map_join(batch.events, "\n", &Jason.encode!(hec_event(&1, settings)))

    {url, headers(destination.credential), :zlib.gzip(body)}
  end

  def build_request(_destination, _batch) do
    raise ArgumentError, "a Splunk HEC destination needs a readable URL"
  end

  # A token that is not sendable (a row that never went through the
  # changeset) is left out rather than quoted in a transport error; Splunk
  # then answers 401, which halts the destination as unauthorized.
  defp headers(token) do
    [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"user-agent", "Stride-AuditStream/1"}
    ] ++ authorization(token)
  end

  defp authorization(token) when is_binary(token) and token != "" do
    if token?(token), do: [{"authorization", "Splunk " <> token}], else: []
  end

  defp authorization(_token), do: []

  defp hec_event(event, settings) do
    %{
      "time" => time(event["occurred_at"]),
      "host" => event["instance"],
      "source" => "stride",
      "sourcetype" => source_type(settings["source_type"]),
      "event" => event
    }
    |> put_index(settings["index"])
  end

  defp source_type(type) when is_binary(type) and type != "", do: type
  defp source_type(_type), do: @default_source_type

  defp put_index(hec_event, index) when is_binary(index) and index != "",
    do: Map.put(hec_event, "index", index)

  defp put_index(hec_event, _index), do: hec_event

  # Epoch seconds with exactly three decimals, written as a JSON number. An
  # unreadable time is left as nil, which Splunk replaces with its receipt
  # time.
  defp time(occurred_at) when is_binary(occurred_at) do
    case DateTime.from_iso8601(occurred_at) do
      {:ok, datetime, _offset} -> datetime |> DateTime.to_unix(:millisecond) |> seconds()
      {:error, _reason} -> nil
    end
  end

  defp time(_occurred_at), do: nil

  defp seconds(ms) do
    fraction = ms |> Integer.mod(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    Jason.Fragment.new("#{Integer.floor_div(ms, 1000)}.#{fraction}")
  end

  @impl true
  def classify(status, body) when status in 200..299 do
    code = code(body)

    if code in @accepted_warning_codes do
      Logger.warning("Splunk HEC accepted an audit stream batch with code #{code}")
    end

    :ok
  end

  def classify(400, body), do: classify_400(code(body))
  def classify(status, _body) when status in [401, 403], do: :unauthorized
  def classify(413, _body), do: :split
  def classify(status, _body) when status in [408, 429], do: {:retry, nil}
  def classify(status, _body) when status in 500..599, do: {:retry, nil}
  def classify(_status, _body), do: :permanent

  defp classify_400(code) when code in @unauthorized_codes, do: :unauthorized
  defp classify_400(code) when code in @bad_data_codes, do: :permanent

  defp classify_400(code) do
    case Map.fetch(@config_errors, code) do
      {:ok, reason} -> {:config_error, reason}
      :error -> :permanent
    end
  end

  @impl true
  def describe_error(status, body) do
    case answer(body) do
      %{code: nil} ->
        nil

      %{code: code, invalid_event: number} ->
        "Splunk HEC answered HTTP #{status} with code #{code}" <>
          meaning(status, code) <> invalid_event(number)
    end
  end

  # English, like every other attempt error and state_reason: the reason a
  # destination is Failing, so the fix is named even where no page shows
  # fix_message/2.
  defp meaning(400, code) when code in @unauthorized_codes,
    do: " (the HEC token is invalid or disabled)"

  defp meaning(400, code) do
    case Map.fetch(@config_errors, code) do
      {:ok, reason} -> " (#{Map.fetch!(@english_fixes, reason)})"
      :error -> ""
    end
  end

  defp meaning(_status, _code), do: ""

  defp invalid_event(nil), do: ""
  defp invalid_event(0), do: ", invalid-event-number 0"

  defp invalid_event(number),
    do: ", invalid-event-number #{number}; the events before it may already be indexed"

  @doc """
  The translated fix for a `{:config_error, reason}` from `classify/2`,
  for the destination page. `settings` names the index for
  `:incorrect_index`.
  """
  @spec fix_message(atom(), map()) :: String.t()
  def fix_message(reason, settings \\ %{})

  def fix_message(:incorrect_index, settings) do
    case (settings || %{})["index"] do
      index when is_binary(index) and index != "" ->
        gettext("The token can't write to index %{index}", index: index)

      _blank ->
        gettext("The token can't write to its default index")
    end
  end

  def fix_message(:indexer_ack_enabled, _settings),
    do: gettext("Turn off indexer acknowledgement on this HEC token")

  def fix_message(:ack_disabled, _settings),
    do:
      gettext(
        "Use a HEC URL without acknowledgement; Stride does not use indexer acknowledgement"
      )

  def fix_message(:query_string_auth, _settings),
    do: gettext("Remove the token from the HEC URL and enter it as the HEC token")

  def fix_message(_reason, _settings),
    do: gettext("Check this destination's Splunk HEC settings")

  @impl true
  def max_event_age, do: :infinity

  # Only Splunk's numbers are kept from the body, never its text.
  defp answer(body) do
    case decode(body) do
      %{} = map ->
        %{code: number(map["code"]), invalid_event: number(map["invalid-event-number"])}

      _other ->
        %{code: nil, invalid_event: nil}
    end
  end

  defp code(body), do: answer(body).code

  # Splunk answers uncompressed unless asked, and Stride never asks, but a
  # proxy in front of it may gzip anyway; reading such a body as text would
  # turn a configuration error into a skippable rejection. One layer only: an
  # inflated body is read as JSON, never inflated again, so nested layers
  # cannot multiply the work.
  defp decode(<<0x1F, 0x8B, _rest::binary>> = gzipped), do: gzipped |> inflate() |> json()
  defp decode(body), do: json(body)

  defp json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> nil
    end
  end

  defp json(_body), do: nil

  # Inflates at most @max_inflated bytes, so a small compressed body cannot
  # expand without bound; anything larger or corrupt is nil.
  defp inflate(gzipped) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      collect(z, :zlib.safeInflate(z, gzipped), [], 0)
    catch
      :error, _reason -> nil
    after
      :zlib.close(z)
    end
  end

  # A :continue that produced nothing is input that ended mid-stream.
  defp collect(z, {:continue, output}, acc, size) do
    grown = size + IO.iodata_length(output)

    if grown > size and grown <= @max_inflated,
      do: collect(z, :zlib.safeInflate(z, []), [acc | output], grown)
  end

  defp collect(_z, {:finished, output}, acc, size) do
    if size + IO.iodata_length(output) <= @max_inflated,
      do: IO.iodata_to_binary([acc | output])
  end

  defp number(value) when is_integer(value) and value in 0..999_999_999, do: value
  defp number(_value), do: nil
end
