defmodule Kanban.AuditStream.Adapters.Datadog do
  @moduledoc """
  The adapter for the Datadog Logs intake
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §5.2).

  ## Settings

    * `site`: required, one of `sites/0`. The intake URL is built from it,
      `https://http-intake.logs.<site>/api/v2/logs`, so a Datadog destination
      has no URL of its own and can never point at another host.
    * `service`: optional, `stride-audit` when blank.
    * `tags`: optional, a list of `key:value` tags. The key is a letter
      followed by letters, digits, `_`, `-`, `.` or `/`, the characters
      Datadog keeps unchanged; the value is non-empty with no comma (the tags
      are sent comma-joined), whitespace, or a control or format character
      such as a zero-width space. The keys `source` and `organization_id` are
      Stride's own, in any case, so a custom tag can never make an entry claim
      another Organization. At most 90 tags of at most 200 characters,
      counted in codepoints, which keeps every entry inside Datadog's limit
      of 100 tags of 256 characters with Stride's own two tags added. Tags
      are checked again at send, and one that fails is left out.

  The destination's `credential` is the API key, sent only as
  `DD-API-KEY`. `validate_credential/2` refuses a key the transport could not
  send as a header value (one header word: visible ASCII, no space), so it is
  refused when it is saved and never quoted in a transport error. A row that
  never went through the changeset is still checked at send: such a key is
  left out, Datadog answers 403, and the destination halts as unauthorized.

  ## Request

  `POST` with `Content-Type: application/json`, `Content-Encoding: gzip`
  (the body is gzipped here) and `User-Agent: Stride-AuditStream/1`. The body
  is a JSON array with one entry per event:

    * `ddsource` is `stride`, `service` the setting, `hostname` the event's
      `instance`;
    * `ddtags` is `source:stride,organization_id:<id>` and then the custom
      tags. The Organization's name is never a tag (D12);
    * `date` is the event's `occurred_at` in epoch milliseconds, so an event
      sent while catching up shows at the time it happened, not when it was
      sent. An unreadable time is left out, and Datadog uses its receipt
      time;
    * `message` is `<action label> by <email>` when the event carries the
      actor's email, `<action label> by user <id>` when it carries only an
      integer user id, and the label alone otherwise, in English. It is built from
      the event as it is sent, after redaction and the destination's
      personal-data setting, so it never names an email the event leaves out;
    * `stride` is the `Kanban.AuditStream.Payload` event.

  ## Age limit

  Datadog drops an entry older than 18 hours while still answering 202, so
  `max_event_age/0` is 17 hours, an hour of margin, for the worker to hold
  older events back (D11).

  Nothing here logs or returns the API key or Datadog's body text.
  """

  @behaviour Kanban.AuditStream.Adapter

  alias Kanban.AuditStream.Destination

  @sites ~w(
    datadoghq.com us3.datadoghq.com us5.datadoghq.com datadoghq.eu
    ap1.datadoghq.com ap2.datadoghq.com uk1.datadoghq.com
    ddog-gov.com us2.ddog-gov.com
  )

  @default_service "stride-audit"
  @max_tags 90
  @max_tag_length 200
  @reserved_tag_keys ~w(source organization_id)

  # A key of a letter and then only the characters Datadog keeps in a tag
  # (letters, digits, _ - . /), so Datadog's normalization, which turns any
  # other character into _, can never turn it into a reserved key; then a
  # non-empty value with no comma, whitespace, control or format character,
  # not starting with a combining mark.
  @tag ~r/\A(?<key>\p{L}[\p{L}\p{N}_.\/-]*):[^,\s\p{Cc}\p{Cf}\p{M}][^,\s\p{Cc}\p{Cf}]*\z/u

  # 17 hours: Datadog drops an entry older than 18 hours with a 202.
  @max_event_age 17 * 60 * 60

  @doc "The Datadog sites a destination can send to, for the destination form."
  @spec sites() :: [String.t()]
  def sites, do: @sites

  @doc "The intake URL for `site`, one of `sites/0`."
  @spec intake_url(String.t()) :: String.t()
  def intake_url(site) when site in @sites, do: "https://http-intake.logs.#{site}/api/v2/logs"

  @impl true
  def validate(settings) when is_map(settings) do
    errors =
      for {reason, false} <- [site: site?(settings["site"]), tags: tags?(settings["tags"])],
          do: {:settings, {"is invalid", validation: reason}}

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp site?(site), do: site in @sites

  defp tags?(nil), do: true

  defp tags?(tags) when is_list(tags),
    do: length(tags) <= @max_tags and Enum.all?(tags, &tag?/1)

  defp tags?(_tags), do: false

  defp tag?(tag) when is_binary(tag) do
    String.valid?(tag) and length(String.codepoints(tag)) <= @max_tag_length and
      tag_key_allowed?(Regex.named_captures(@tag, tag))
  end

  defp tag?(_tag), do: false

  defp tag_key_allowed?(%{"key" => key}), do: String.downcase(key) not in @reserved_tag_keys
  defp tag_key_allowed?(nil), do: false

  @impl true
  def validate_credential(key, _settings) do
    if is_binary(key) and key != "" and not api_key?(key),
      do: {:error, [credential: {"is invalid", validation: :header_value}]},
      else: :ok
  end

  # An API key is one header word: visible ASCII with no space, so the
  # transport sends it rather than refusing it (Mint quotes a refused value
  # in its error).
  defp api_key?(key), do: key |> :binary.bin_to_list() |> Enum.all?(&(&1 in 33..126))

  @impl true
  def build_request(%Destination{} = destination, batch) do
    settings = destination.settings || %{}

    case settings["site"] do
      site when site in @sites ->
        {intake_url(site), headers(destination.credential), body(batch, settings)}

      _other ->
        raise ArgumentError, "a Datadog destination needs one of the Datadog sites"
    end
  end

  defp body(batch, settings) do
    batch.events
    |> Enum.map(&entry(&1, settings, batch.organization))
    |> Jason.encode!()
    |> :zlib.gzip()
  end

  defp headers(api_key) do
    [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"user-agent", "Stride-AuditStream/1"}
    ] ++ api_key_header(api_key)
  end

  # A key that is not sendable (a row that never went through the changeset)
  # is left out rather than quoted in a transport error.
  defp api_key_header(key) when is_binary(key) and key != "" do
    if api_key?(key), do: [{"dd-api-key", key}], else: []
  end

  defp api_key_header(_key), do: []

  defp entry(event, settings, organization) do
    %{
      "ddsource" => "stride",
      "service" => service(settings["service"]),
      "hostname" => event["instance"],
      "ddtags" => ddtags(organization, settings["tags"]),
      "message" => message(event),
      "stride" => event
    }
    |> put_date(date(event["occurred_at"]))
  end

  defp service(service) when is_binary(service) and service != "", do: service
  defp service(_service), do: @default_service

  defp ddtags(organization, tags) do
    custom = if is_list(tags), do: Enum.filter(tags, &tag?/1), else: []
    Enum.join(["source:stride", "organization_id:#{organization.id}" | custom], ",")
  end

  defp message(event) do
    label = event["action_label"] || event["action"]
    actor = event["actor"] || %{}

    cond do
      present?(actor["email"]) -> "#{label} by #{actor["email"]}"
      is_integer(actor["user_id"]) -> "#{label} by user #{actor["user_id"]}"
      true -> label
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp date(occurred_at) when is_binary(occurred_at) do
    case DateTime.from_iso8601(occurred_at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> nil
    end
  end

  defp date(_occurred_at), do: nil

  defp put_date(entry, nil), do: entry
  defp put_date(entry, date), do: Map.put(entry, "date", date)

  @impl true
  def classify(status, _body) when status in 200..299, do: :ok
  def classify(status, _body) when status in [408, 429], do: {:retry, nil}
  def classify(status, _body) when status in 500..599, do: {:retry, nil}
  def classify(413, _body), do: :split
  def classify(status, _body) when status in [401, 403], do: :unauthorized
  def classify(_status, _body), do: :permanent

  @impl true
  def max_event_age, do: @max_event_age
end
