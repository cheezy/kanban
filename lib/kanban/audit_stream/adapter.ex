defmodule Kanban.AuditStream.Adapter do
  @moduledoc """
  The behaviour each destination kind implements
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §5.4).

  An adapter is pure: it checks a kind's settings, turns a batch of built
  `Kanban.AuditStream.Payload` events into a request, and classifies the
  response. The worker owns reading, batching, retries, the cursor,
  telemetry and attempts, and `Kanban.Webhooks.Transport` sends the bytes it
  is given, so an adapter that compresses its body sets `Content-Encoding`
  itself.

  `build_request/2` takes the destination and a `t:batch/0`, not only the
  events, because the batch id and the Organization belong in the request
  (§5.3). The batch id must be the same on every retry of the same batch.

  An adapter that sends the destination's `credential` in a header
  implements the optional `validate_credential/2`, so a value the transport
  would refuse (and quote in its error), or a header name with no value, is
  refused when it is saved instead of being dropped or failing at send.

  The batch cut counts each event as the adapter writes it, so a full batch
  stays within 900,000 bytes of uncompressed body
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.2). An adapter that wraps
  each event, such as Datadog's entry or Splunk's HEC event, or puts the
  events in an envelope, implements the optional `entry_size/3` and
  `envelope_size/2`; `entry_size/4` and `envelope_size/3` call them, and
  default to the event's JSON size plus one separator and to nothing.

  `module_for/1` maps a kind to its adapter. A kind whose adapter has not
  been written yet maps to nil, and `Kanban.AuditStream.Destination` then
  skips the kind's own settings check.
  """

  alias Kanban.AuditStream.Adapters
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Payload

  @typedoc """
  One batch to send: its id (the same on every retry), the built events,
  the Organization, and optionally the unix time to sign at (defaults to
  now).
  """
  @type batch :: %{
          required(:batch_id) => String.t(),
          required(:events) => [Payload.t()],
          required(:organization) => Payload.organization(),
          optional(:signed_at) => integer()
        }

  @type header :: {String.t(), String.t()}

  @type classification ::
          :ok
          | {:retry, retry_after_seconds :: non_neg_integer() | nil}
          | :split
          | :permanent
          | :unauthorized
          | {:config_error, reason :: atom()}

  @doc """
  Checks the kind's own rules for `settings` (string keys). Errors are
  `Ecto.Changeset` errors, such as `[settings: {"is invalid", validation: :format}]`.
  """
  @callback validate(settings :: map()) :: :ok | {:error, keyword()}

  @doc "Builds the request for `batch`: the URL, the headers and the body bytes."
  @callback build_request(Destination.t(), batch()) ::
              {url :: String.t(), [header()], body :: binary()}

  @doc "Classifies a response by its status and body."
  @callback classify(status :: integer(), body :: binary()) :: classification()

  @doc "The oldest event the destination accepts, in seconds, or `:infinity`."
  @callback max_event_age() :: pos_integer() | :infinity

  @doc """
  A short error for a failed response, composed by Stride and never echoing
  the receiver's body, or nil when there is nothing better to say.
  """
  @callback describe_error(status :: integer(), body :: binary()) :: String.t() | nil

  @doc """
  Checks the destination's `credential` (nil when there is none) with its
  `settings` for the kind's own rules, such as being sendable as an HTTP
  header value and coming with the header name it is sent under. Called by
  `Kanban.AuditStream.Destination` on every change of a readable
  credential. Errors are `Ecto.Changeset` errors, such as
  `[credential: {"is invalid", validation: :header_value}]`, and never carry
  the value.
  """
  @callback validate_credential(credential :: String.t() | nil, settings :: map()) ::
              :ok | {:error, keyword()}

  @doc """
  Checks a URL being set on the destination for the kind's own rules, such
  as the path a collector must have. Called by
  `Kanban.AuditStream.Destination` only when the URL changes. Errors are
  `Ecto.Changeset` errors, such as `[url: {"is invalid", validation: :path}]`,
  and never carry the URL.
  """
  @callback validate_url(url :: String.t()) :: :ok | {:error, keyword()}

  @doc """
  The bytes one built `Kanban.AuditStream.Payload` event takes in the
  uncompressed body `build_request/2` writes for `destination`, counting one
  separator after it. Measured on the event as given, which the cut has
  already redacted and stripped of personal data.
  """
  @callback entry_size(Destination.t(), event :: Payload.t(), Payload.organization()) ::
              pos_integer()

  @doc """
  The bytes the uncompressed body takes beyond its events' `entry_size/3`,
  such as an envelope around them, less the one separator the last event
  does not have. Never negative, so an adapter with no envelope (Splunk
  HEC) counts one byte over its body, never under.
  """
  @callback envelope_size(Destination.t(), Payload.organization()) :: non_neg_integer()

  @optional_callbacks describe_error: 2,
                      validate_credential: 2,
                      validate_url: 1,
                      entry_size: 3,
                      envelope_size: 2

  @adapters %{
    datadog: Adapters.Datadog,
    https: Adapters.Https,
    splunk_hec: Adapters.SplunkHec
  }

  @doc """
  The bytes `event` takes in `adapter`'s uncompressed body for `destination`:
  the adapter's `entry_size/3`, or, for an adapter without one (or no
  adapter), the event's JSON size plus one separator.
  """
  @spec entry_size(module() | nil, Destination.t(), Payload.t(), Payload.organization()) ::
          pos_integer()
  def entry_size(adapter, destination, event, organization) do
    if implements?(adapter, :entry_size, 3),
      do: adapter.entry_size(destination, event, organization),
      else: json_size(event) + 1
  end

  @doc """
  The bytes `adapter`'s uncompressed body takes for `destination` beyond its
  events' entry sizes: the adapter's `envelope_size/2`, or 0 for an adapter
  without one (or no adapter).
  """
  @spec envelope_size(module() | nil, Destination.t(), Payload.organization()) ::
          non_neg_integer()
  def envelope_size(adapter, destination, organization) do
    if implements?(adapter, :envelope_size, 2),
      do: adapter.envelope_size(destination, organization),
      else: 0
  end

  @doc "The byte size of `term` encoded as JSON."
  @spec json_size(term()) :: non_neg_integer()
  def json_size(term), do: term |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp implements?(nil, _function, _arity), do: false

  defp implements?(adapter, function, arity),
    do: Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity)

  @doc "The adapter module for `kind`, or nil when the kind has none yet."
  @spec module_for(atom() | nil) :: module() | nil
  def module_for(kind), do: Map.get(@adapters, kind)
end
