defmodule KanbanWeb.OrgLive.AuditStreamingRow do
  @moduledoc """
  What the Audit streaming page (`KanbanWeb.OrgLive.AuditStreaming`) shows of
  one destination, and the text of a test event's result
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §10.2, §10.3, §12.2, §12.5).

  `to_view/1` turns a `%{destination: destination, status: status}` from
  `Kanban.AuditStream.list_destinations_with_status/2` into a plain map that
  holds no secret: the destination's URL, credential and signing secrets are
  never copied, so they never reach the socket or the page. The host and the
  4-character hints are plain columns, so a destination whose secrets can't be
  decrypted (D17) still shows them.

  Pure functions only: no database access.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.AuditStream.Adapters.Datadog
  alias Kanban.AuditStream.Destination
  alias KanbanWeb.TimeAgo

  @typedoc "One destination row, with no secret in it."
  @type t :: %{
          id: integer(),
          name: String.t(),
          kind: atom(),
          host: String.t() | nil,
          hint: String.t() | nil,
          enabled: boolean(),
          state: atom(),
          reason: String.t() | nil,
          credentials_unreadable: boolean(),
          last_success_at: DateTime.t() | nil,
          lag: map()
        }

  @doc "The row for one destination and its status. See the moduledoc."
  @spec to_view(%{destination: Destination.t(), status: map()}) :: t()
  def to_view(%{destination: %Destination{} = destination, status: status}) do
    %{
      id: destination.id,
      name: destination.name,
      kind: destination.kind,
      host: host(destination),
      hint: hint(destination),
      enabled: destination.enabled,
      state: status.state,
      reason: reason(status),
      credentials_unreadable: status.halted_reason == :credentials_unreadable,
      last_success_at: status.last_success_at,
      lag: status.lag
    }
  end

  @doc "The destination type's label: Splunk, Datadog or HTTPS endpoint."
  @spec type_label(atom()) :: String.t()
  def type_label(:splunk_hec), do: gettext("Splunk")
  def type_label(:datadog), do: gettext("Datadog")
  def type_label(:https), do: gettext("HTTPS endpoint")

  @doc """
  The host the destination sends to. A Datadog destination stores no URL, so
  its host comes from its site setting.
  """
  @spec host(Destination.t()) :: String.t() | nil
  def host(%Destination{kind: :datadog, settings: %{"site" => site}}) when is_binary(site) do
    if site in Datadog.sites(), do: site |> Datadog.intake_url() |> URI.parse() |> Map.get(:host)
  end

  def host(%Destination{url_host: host}), do: host

  @doc """
  The last 4 characters of the credential, or of an HTTPS endpoint's URL when
  it has no credential, as `"•••• 1a2b"`; `nil` when there is no hint.
  """
  @spec hint(Destination.t()) :: String.t() | nil
  def hint(%Destination{credential_hint: hint}) when is_binary(hint) and hint != "",
    do: "•••• " <> hint

  def hint(%Destination{kind: :https, url_hint: hint}) when is_binary(hint) and hint != "",
    do: "•••• " <> hint

  def hint(%Destination{}), do: nil

  @doc "The status pill's label."
  @spec state_label(atom()) :: String.t()
  def state_label(:healthy), do: gettext("Healthy")
  def state_label(:retrying), do: gettext("Retrying")
  def state_label(:failing), do: gettext("Failing")
  def state_label(:paused), do: gettext("Paused")
  def state_label(:needs_attention), do: gettext("Needs attention")

  @doc "The status token (`--st-<name>`) the pill is drawn with."
  @spec state_token(atom()) :: String.t()
  def state_token(:healthy), do: "done"
  def state_token(:retrying), do: "doing"
  def state_token(:paused), do: "backlog"
  def state_token(_failing_or_halted), do: "blocked"

  @doc """
  **Behind by**: the events waiting and the oldest one's age, or **Up to
  date**. Events held above the horizon are counted in `events_waiting`
  (`Kanban.AuditStream.Status`), so a held horizon never reads as up to date.
  """
  @spec behind_by(map()) :: String.t()
  def behind_by(%{up_to_date: true, events_waiting: 0}), do: gettext("Up to date")

  def behind_by(%{events_waiting: count, oldest_waiting_at: %DateTime{} = oldest}) do
    ngettext(
      "%{count} event waiting, the oldest from %{age}",
      "%{count} events waiting, the oldest from %{age}",
      count,
      age: TimeAgo.format_age(oldest, :coarse)
    )
  end

  def behind_by(%{events_waiting: count}),
    do: ngettext("%{count} event waiting", "%{count} events waiting", count)

  @doc "**Last delivered**: how long ago and the time in UTC, or Never."
  @spec last_delivered(DateTime.t() | nil) :: String.t()
  def last_delivered(nil), do: gettext("Never")

  def last_delivered(%DateTime{} = at) do
    gettext("%{age} · %{time} UTC",
      age: TimeAgo.format_age(at, :coarse),
      time: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
    )
  end

  @doc """
  A test event's result as `{tone, message}`, `tone` being `:ok` or
  `:error`. Only the coarse class is shown, never a transport reason, an
  address or a body (§10.3, §12.5).
  """
  @spec test_result(term()) :: {:ok | :error, String.t()}
  def test_result({:ok, :delivered}), do: {:ok, gettext("Test event delivered")}
  def test_result({:ok, :could_not_connect}), do: {:error, gettext("Could not connect")}

  def test_result({:ok, :certificate_invalid}),
    do: {:error, gettext("The certificate could not be verified")}

  def test_result({:ok, :credentials_refused}),
    do: {:error, gettext("The destination refused the credentials")}

  def test_result({:ok, {:http_error, status}}) when is_integer(status),
    do: {:error, gettext("The destination answered with an error (%{status})", status: status)}

  def test_result({:error, :credentials_unreadable}), do: {:error, credentials_unreadable()}

  def test_result({:error, {:rate_limited, retry_after_ms}}) when is_integer(retry_after_ms) do
    minutes = max(1, div(retry_after_ms + 59_999, 60_000))

    {:error,
     ngettext(
       "This Organization has sent as many test events as it can this hour. Try again in %{count} minute.",
       "This Organization has sent as many test events as it can this hour. Try again in %{count} minutes.",
       minutes
     )}
  end

  def test_result(_other), do: {:error, gettext("The test event could not be sent.")}

  @doc "The reason shown for a destination halted with `credentials_unreadable` (D17)."
  @spec credentials_unreadable() :: String.t()
  def credentials_unreadable, do: gettext("Credentials can't be read. Enter them again.")

  # Retrying, Failing and Needs attention show why; a paused destination's
  # stored reason is from before it was paused, so it shows none.
  defp reason(%{halted_reason: :credentials_unreadable}), do: credentials_unreadable()
  defp reason(%{state: :paused}), do: nil
  defp reason(%{state: :healthy}), do: nil
  defp reason(%{state_reason: reason}), do: reason
end
