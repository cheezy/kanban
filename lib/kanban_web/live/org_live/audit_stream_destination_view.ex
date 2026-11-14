defmodule KanbanWeb.OrgLive.AuditStreamDestinationView do
  @moduledoc """
  What the destination page (`KanbanWeb.OrgLive.AuditStreamDestination`)
  shows of one audit stream destination
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4, §8.6, §8.7, §10.4, §12.2).

  `to_view/1` turns a `%Kanban.AuditStream.Destination{}` into a plain map
  with no secret in it: the URL, credential and signing secrets are never
  copied, so they never reach the socket or the page. Only whether the
  signing secret can be read is kept, so the page can say a rotation has no
  24-hour overlap (D17).

  `actions/2` decides which of **Retry now** and **Skip this batch** the page
  offers: both only for a `rejected_batch` halt, and Skip only while a batch
  is pending. The context refuses the same calls for any other halt, so a
  crafted event changes nothing either way.

  Pure functions only: no database access.
  """
  use Gettext, backend: KanbanWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router,
    statics: KanbanWeb.static_paths()

  alias Kanban.AuditStream.Adapters.SplunkHec
  alias Kanban.AuditStream.Destination
  alias KanbanWeb.OrgLive.AuditStreamingRow
  alias KanbanWeb.OrgLive.AuditStreamKinds

  @error_preview 80

  @typedoc "The destination as the page shows it, with no secret in it."
  @type t :: %{
          id: integer(),
          name: String.t(),
          kind: atom(),
          host: String.t() | nil,
          hint: String.t() | nil,
          enabled: boolean(),
          settings: [{String.t(), String.t()}],
          index: String.t() | nil,
          include_personal_data: boolean(),
          excluded_actions: [String.t()],
          signing_secret_unreadable: boolean(),
          rotate_again_at: DateTime.t() | nil
        }

  @doc "The destination as the page shows it. See the moduledoc."
  @spec to_view(Destination.t(), DateTime.t()) :: t()
  def to_view(%Destination{} = destination, now \\ DateTime.utc_now()) do
    %{
      id: destination.id,
      name: destination.name,
      kind: destination.kind,
      host: AuditStreamingRow.host(destination),
      hint: AuditStreamingRow.hint(destination),
      enabled: destination.enabled,
      settings: settings(destination),
      index: (destination.settings || %{})["index"],
      include_personal_data: destination.include_personal_data,
      excluded_actions: destination.excluded_actions || [],
      signing_secret_unreadable: destination.signing_secret == :unreadable,
      rotate_again_at: rotate_again_at(destination, now)
    }
  end

  # The kind's non-secret settings, labelled, in a fixed order; blank ones
  # are left out.
  defp settings(%Destination{kind: kind, settings: settings}) do
    settings = settings || %{}

    kind
    |> setting_labels()
    |> Enum.flat_map(&setting_row(&1, settings))
  end

  defp setting_row({key, label}, settings) do
    case Map.get(settings, key) do
      value when is_binary(value) and value != "" -> [{label, setting_value(key, value)}]
      [_ | _] = values -> [{label, Enum.join(values, ", ")}]
      _blank -> []
    end
  end

  # A stored format is shown by the name the form offers it under.
  defp setting_value("format", value), do: AuditStreamKinds.format_label(value)
  defp setting_value(_key, value), do: value

  defp setting_labels(:splunk_hec),
    do: [{"index", gettext("Index")}, {"source_type", gettext("Source type")}]

  defp setting_labels(:datadog),
    do: [{"site", gettext("Site")}, {"service", gettext("Service")}, {"tags", gettext("Tags")}]

  defp setting_labels(:https),
    do: [{"format", gettext("Format")}, {"header_name", AuditStreamKinds.header_name_label()}]

  # A readable secret rotated less than 24 hours ago can't be rotated again
  # until then (§10.4). An unreadable one is always replaced at once.
  defp rotate_again_at(
         %Destination{kind: :https, previous_secret_expires_at: %DateTime{} = at} = destination,
         now
       ) do
    readable? =
      destination.signing_secret != :unreadable and
        destination.previous_signing_secret != :unreadable

    if readable? and DateTime.after?(at, now), do: at
  end

  defp rotate_again_at(%Destination{}, _now), do: nil

  @doc """
  Which batch actions the page offers: `%{retry: boolean, skip: boolean}`.
  Both only for a `rejected_batch` halt; Skip only while a batch is pending.
  """
  @spec actions(map(), map() | nil) :: %{retry: boolean(), skip: boolean()}
  def actions(%{halted_reason: :rejected_batch}, batch), do: %{retry: true, skip: batch != nil}
  def actions(_status, _batch), do: %{retry: false, skip: false}

  @doc """
  Why a halted destination is halted, in words; `nil` for one that is not.
  `credentials_unreadable` is shown with its own link, so it is here too.
  """
  @spec halted_text(atom() | nil) :: String.t() | nil
  def halted_text(:rejected_batch),
    do:
      gettext(
        "The destination rejected the same batch on every try. Stride never skips a batch on its own: fix the cause at the destination and choose Retry now, or skip the batch."
      )

  def halted_text(:blocked_address),
    do:
      gettext(
        "The URL's host resolves only to addresses Stride may not send to. Nothing is sent until the URL is changed."
      )

  def halted_text(:txid_reset),
    do: gettext("The database was moved. An operator must re-seed audit streaming.")

  def halted_text(:credentials_unreadable), do: AuditStreamingRow.credentials_unreadable()
  def halted_text(_not_halted), do: nil

  @doc """
  The fix for a configuration error, when the destination's newest attempt
  was one and it is not halted for another reason (§5.1, §8.4); `nil`
  otherwise. A configuration error leaves `halted_reason` unset, so it is
  read from the attempt, whose error is Stride's own text.
  """
  @spec config_error_fix(t(), map(), [map()]) :: String.t() | nil
  def config_error_fix(view, status, attempts)

  def config_error_fix(%{kind: kind} = view, %{halted_reason: nil, state: state}, [
        %{outcome: :config_error, error: error} | _older
      ])
      when state not in [:healthy, :paused] do
    if kind == :splunk_hec,
      do:
        error
        |> SplunkHec.config_error_reason()
        |> SplunkHec.fix_message(%{"index" => view.index}),
      else: gettext("Check this destination's settings.")
  end

  def config_error_fix(_view, _status, _attempts), do: nil

  @doc """
  Whether a rejected batch's answer was a Splunk 400 naming an
  `invalid-event-number` above 0, so the events before it may already be in
  Splunk (§10.4).
  """
  @spec partially_indexed?(atom(), map() | nil) :: boolean()
  def partially_indexed?(:splunk_hec, %{http_status: 400, error: error}),
    do: SplunkHec.partially_indexed?(error)

  def partially_indexed?(_kind, _batch), do: false

  @doc "A rejected batch's answer as Stride classified it."
  @spec classification(map()) :: String.t()
  def classification(%{error: error}) when is_binary(error) and error != "", do: error

  def classification(%{http_status: status}) when is_integer(status),
    do: gettext("HTTP %{status}", status: status)

  def classification(_batch), do: gettext("No answer was recorded.")

  @doc "The Skip this batch confirmation (§10.4)."
  @spec skip_confirmation(non_neg_integer()) :: String.t()
  def skip_confirmation(events) do
    ngettext(
      "This event will not be sent to this destination. It stays in the audit log and in exports.",
      "These %{count} events will not be sent to this destination. They stay in the audit log and in exports.",
      events
    )
  end

  @doc "A gap's reason, in words."
  @spec gap_reason(atom()) :: String.t()
  def gap_reason(:retention), do: gettext("Deleted by retention before it was sent")
  def gap_reason(:too_old), do: gettext("Too old for Datadog")
  def gap_reason(:database_move), do: gettext("Left behind by a database move")

  @doc "How many events a gap lost."
  @spec events_lost(non_neg_integer()) :: String.t()
  def events_lost(events),
    do: ngettext("%{count} event lost", "%{count} events lost", events)

  @doc "An attempt's outcome, in words."
  @spec outcome_label(atom()) :: String.t()
  def outcome_label(:delivered), do: gettext("Delivered")
  def outcome_label(:retry), do: gettext("Will retry")
  def outcome_label(:rejected), do: gettext("Rejected")
  def outcome_label(:unauthorized), do: gettext("Credentials refused")
  def outcome_label(:config_error), do: gettext("Configuration error")
  def outcome_label(:blocked), do: gettext("Blocked address")
  def outcome_label(:skipped), do: gettext("Skipped")

  @doc "The status token (`--st-<name>`) an outcome is drawn with."
  @spec outcome_token(atom()) :: String.t()
  def outcome_token(:delivered), do: "done"
  def outcome_token(:retry), do: "doing"
  def outcome_token(:skipped), do: "backlog"
  def outcome_token(_failed), do: "blocked"

  @doc "A size in bytes, as B, KB or MB; a dash when unknown."
  @spec size(integer() | nil) :: String.t()
  def size(nil), do: "—"
  def size(bytes) when bytes < 1024, do: gettext("%{count} B", count: bytes)

  def size(bytes) when bytes < 1024 * 1024,
    do: gettext("%{count} KB", count: one_decimal(bytes / 1024))

  def size(bytes), do: gettext("%{count} MB", count: one_decimal(bytes / (1024 * 1024)))

  # 2.0 reads as 2, 1.46 as 1.5.
  defp one_decimal(value) do
    rounded = Float.round(value, 1)
    if rounded == trunc(rounded), do: trunc(rounded), else: rounded
  end

  @doc """
  An attempt's error, shortened for its table cell. The page renders it
  through HEEx, which escapes it; the full text goes in the cell's `title`.
  """
  @spec error_preview(String.t() | nil) :: String.t()
  def error_preview(nil), do: ""

  def error_preview(error) when is_binary(error) do
    if String.length(error) > @error_preview,
      do: String.slice(error, 0, @error_preview) <> "…",
      else: error
  end

  @doc "A time in UTC, to the second; a dash for none."
  @spec utc(DateTime.t() | nil) :: String.t()
  def utc(nil), do: "—"
  def utc(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  @doc "The path to the destination's edit form (B3)."
  @spec edit_path(integer()) :: String.t()
  def edit_path(id) when is_integer(id), do: ~p"/org/audit/streaming/#{id}/edit"
end
