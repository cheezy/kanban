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

  @optional_callbacks describe_error: 2, validate_credential: 2, validate_url: 1

  @adapters %{
    datadog: Adapters.Datadog,
    https: Adapters.Https,
    splunk_hec: Adapters.SplunkHec
  }

  @doc "The adapter module for `kind`, or nil when the kind has none yet."
  @spec module_for(atom() | nil) :: module() | nil
  def module_for(kind), do: Map.get(@adapters, kind)
end
