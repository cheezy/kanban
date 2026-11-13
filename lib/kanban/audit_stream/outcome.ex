defmodule Kanban.AuditStream.Outcome do
  @moduledoc """
  What one send of an audit stream batch means for the destination, its
  cursor and its attempt record (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`
  §8.2, §8.4, §8.7). Pure: `Kanban.AuditStream.DispatchWorker` reads the rows,
  sends, and writes what `plan/5` and `halt/4` return.

  ## Classes

  `classify/3` turns a send into one class:

    * `:delivered` - a 2xx;
    * `{:retry, seconds | nil}` - 5xx, 408, 429, a transport error, or a host
      that does not resolve, with the destination's `Retry-After` (whole
      seconds only; an HTTP date is ignored);
    * `:split` - a 413 for a batch of more than one event;
    * `:permanent` - any other refusal, and a 413 for a single event;
    * `:unauthorized`, `{:config_error, reason}` - as the adapter says;
    * `{:blocked, reason}` - `Kanban.Webhooks.UrlGuard` refused the URL for
      any reason other than an unresolvable host.

  ## State

  A destination is `:retrying` after its first failure and `:failing` once
  30 minutes have passed without a success. `failing_since` records when the
  current run of failures began: it is set by the first failure and cleared
  by a success, so it is the start of the 30 minutes. An unauthorized answer,
  a configuration error, a blocked address, a `txid` reset, unreadable
  credentials and a batch rejected for the third time make it `:failing` at
  once, the last four also setting `halted_reason`.

  `pending_attempts` counts the permanent rejections of the pending batch:
  the third halts the destination with `rejected_batch`, the first two are
  retried 5 minutes apart, so the three tries span about 10 minutes.

  `audit_stream_failing` is recorded on the move into `:failing` and
  `audit_stream_recovered` on the move from `:failing` back to `:healthy`,
  each once per move: a destination already Failing records nothing more,
  and a halted one is not sent to again until a person clears the halt.

  ## Error text

  An attempt's error and the destination's `state_reason` come from Stride's
  own classification, or from the adapter's `describe_error/2` when it has
  one, and never from the response body (§8.7).
  """

  alias Kanban.AuditStream.Destination
  alias Kanban.Webhooks.UrlGuard

  @type class ::
          :delivered
          | {:retry, non_neg_integer() | nil}
          | :split
          | :permanent
          | :unauthorized
          | {:config_error, atom()}
          | {:blocked, atom()}

  @typedoc "What a send returned: a response, a transport error, or a refused URL."
  @type result ::
          {:response,
           %{
             required(:status) => integer(),
             required(:body) => binary(),
             optional(:retry_after) => String.t() | nil
           }}
          | {:transport_error, Exception.t() | term()}
          | {:guard_error, atom()}

  @base_seconds 15
  @max_backoff 900
  @max_retry_after 3_600
  @failing_after 1_800
  @permanent_spacing 300
  @permanent_tries 3
  @error_max 200

  @credentials_unreadable "Credentials can't be read. Enter them again."
  @txid_reset "The database was moved. An operator must re-seed audit streaming."
  @reseeded "Audit streaming was re-seeded after the database move. The next delivery clears this."

  @doc "The `state_reason` a halt with `credentials_unreadable` sets."
  @spec credentials_unreadable_reason() :: String.t()
  def credentials_unreadable_reason, do: @credentials_unreadable

  @doc "The `state_reason` a halt with `txid_reset` sets."
  @spec txid_reset_reason() :: String.t()
  def txid_reset_reason, do: @txid_reset

  @doc """
  The `state_reason` the re-seed leaves on a destination whose `txid_reset`
  halt it cleared, until its next delivery returns it to healthy.
  """
  @spec reseeded_reason() :: String.t()
  def reseeded_reason, do: @reseeded

  @doc """
  The class of a send of `event_count` events, classified by `adapter` when
  the destination answered.
  """
  @spec classify(result(), module(), pos_integer()) :: class()
  def classify({:response, %{status: status, body: body} = response}, adapter, event_count) do
    case adapter.classify(status, body) do
      :ok -> :delivered
      {:retry, seconds} -> {:retry, seconds || parse_retry_after(response[:retry_after])}
      :split when event_count > 1 -> :split
      :split -> :permanent
      other -> other
    end
  end

  def classify({:transport_error, _error}, _adapter, _event_count), do: {:retry, nil}
  def classify({:guard_error, :unresolvable}, _adapter, _event_count), do: {:retry, nil}
  def classify({:guard_error, reason}, _adapter, _event_count), do: {:blocked, reason}

  @doc """
  A `Retry-After` value in whole seconds, or nil for anything else (an HTTP
  date, a negative or malformed value, or none).
  """
  @spec parse_retry_after(String.t() | nil) :: non_neg_integer() | nil
  def parse_retry_after(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> nil
    end
  end

  def parse_retry_after(_value), do: nil

  @doc """
  Seconds until the next try after a retryable failure: 15 s ×
  2^`failures` with up to 20% jitter added, capped at 15 minutes, or
  `retry_after` when that is later, up to 1 hour.
  """
  @spec delay(non_neg_integer(), non_neg_integer() | nil) :: pos_integer()
  def delay(failures, retry_after \\ nil) when is_integer(failures) and failures >= 0 do
    failures
    |> Oban.Backoff.exponential(mult: @base_seconds, max_pow: 6)
    |> Oban.Backoff.jitter(mode: :inc, mult: 0.2)
    |> min(@max_backoff)
    |> later(retry_after)
  end

  # Unauthorized and configuration errors keep trying at the capped interval.
  defp capped_delay(retry_after), do: later(@max_backoff, retry_after)

  defp later(seconds, retry_after) when is_integer(retry_after) and retry_after > seconds,
    do: min(retry_after, @max_retry_after)

  defp later(seconds, _retry_after), do: seconds

  @doc """
  The attempt outcome a class is recorded with (`Kanban.AuditStream.Attempt`).
  A 413 split is recorded as `:rejected`; its error says it is sent again in
  halves.
  """
  @spec attempt_outcome(class()) :: atom()
  def attempt_outcome(:delivered), do: :delivered
  def attempt_outcome({:retry, _seconds}), do: :retry
  def attempt_outcome(:split), do: :rejected
  def attempt_outcome(:permanent), do: :rejected
  def attempt_outcome(:unauthorized), do: :unauthorized
  def attempt_outcome({:config_error, _reason}), do: :config_error
  def attempt_outcome({:blocked, _reason}), do: :blocked

  @doc """
  The short error for a failed send, nil for a delivered one. It names the
  status, or says only that the destination could not be reached for any
  transport failure, and the adapter's `describe_error/2` replaces a status
  text when it gives one; the response body and the transport reason are
  never quoted.
  """
  @spec error_text(class(), result(), module()) :: String.t() | nil
  def error_text(:delivered, _result, _adapter), do: nil
  def error_text(class, result, adapter), do: class |> text(result, adapter) |> cut()

  defp text(class, {:response, %{status: status, body: body}}, adapter),
    do: described(adapter, status, body) || status_text(class, status)

  # One text for every transport failure: org-admins read this in the
  # attempt list and the status, and a refused, closed, silent or TLS-failed
  # port told apart there would let them probe another host's ports (§12.5),
  # the thing the test event's coarse classes prevent.
  defp text(_class, {:transport_error, _error}, _adapter),
    do: "Could not connect to the destination"

  defp text(_class, {:guard_error, reason}, _adapter),
    do: "The URL " <> UrlGuard.error_message(reason)

  # The attempt's error column holds 200 codepoints, and state_reason gets
  # the same text.
  defp cut(text), do: text |> String.codepoints() |> Enum.take(@error_max) |> Enum.join()

  defp described(adapter, status, body) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :describe_error, 2) do
      case adapter.describe_error(status, body) do
        text when is_binary(text) and text != "" -> text
        _none -> nil
      end
    end
  end

  defp status_text({:retry, _seconds}, status), do: "HTTP #{status} from the destination"

  defp status_text(:split, status),
    do: "Too large for the destination (HTTP #{status}); sending it in halves"

  defp status_text(:permanent, 413), do: "Too large for the destination (HTTP 413)"
  defp status_text(:permanent, status), do: "Rejected by the destination (HTTP #{status})"

  defp status_text(:unauthorized, status),
    do: "The destination refused the credentials (HTTP #{status})"

  defp status_text({:config_error, reason}, status),
    do: "The destination reported a configuration error (#{reason}, HTTP #{status})"

  @doc """
  What a send of `batch` means, as attribute maps for the cursor and the
  destination's `Destination.status_changeset/2`, the audit event to record
  (`{:failing, reason}`, `:recovered` or nil) and when the follow-up run is
  due (nil for none).

  `batch` holds the sent `events` and their `last` (`txid`, `id`); `now` is
  the time the outcome is recorded.
  """
  @spec plan(class(), String.t() | nil, Destination.t(), map(), DateTime.t()) :: %{
          cursor: map(),
          destination: map(),
          audit: {:failing, atom()} | :recovered | nil,
          follow_up_at: DateTime.t() | nil
        }
  def plan(:delivered, _error, destination, batch, now) do
    {last_txid, last_id} = batch.last

    %{
      cursor:
        Map.merge(cleared_pending(), %{
          last_txid: last_txid,
          last_event_id: last_id,
          last_inserted_at: batch.events |> List.last() |> Map.fetch!(:inserted_at)
        }),
      destination: %{
        state: :healthy,
        state_reason: nil,
        failing_since: nil,
        consecutive_failures: 0,
        last_success_at: DateTime.truncate(now, :second)
      },
      audit: if(destination.state == :failing, do: :recovered),
      follow_up_at: now
    }
  end

  def plan({:retry, retry_after}, error, destination, _batch, now) do
    due = DateTime.add(now, delay(destination.consecutive_failures, retry_after), :second)
    {status, audit} = failure(destination, error, now)

    %{cursor: %{next_attempt_at: due}, destination: status, audit: audit, follow_up_at: due}
  end

  def plan(:permanent, error, destination, batch, now) do
    tries = batch.pending_attempts + 1

    if tries >= @permanent_tries do
      destination
      |> failed_halt(:rejected_batch, error, now)
      |> Map.put(:cursor, %{pending_attempts: tries, next_attempt_at: nil})
    else
      due = DateTime.add(now, @permanent_spacing, :second)
      {status, audit} = failure(destination, error, now)

      %{
        cursor: %{pending_attempts: tries, next_attempt_at: due},
        destination: status,
        audit: audit,
        follow_up_at: due
      }
    end
  end

  def plan(:split, _error, _destination, batch, now) do
    half = Enum.take(batch.events, div(length(batch.events) + 1, 2))
    last = List.last(half)

    %{
      cursor: %{
        pending_batch_id: Ecto.UUID.generate(),
        pending_last_txid: last.txid,
        pending_last_id: last.id,
        pending_attempts: 0,
        next_attempt_at: nil
      },
      destination: %{},
      audit: nil,
      follow_up_at: now
    }
  end

  def plan(:unauthorized, error, destination, _batch, now),
    do: refused(:unauthorized, error, destination, now)

  def plan({:config_error, _reason}, error, destination, _batch, now),
    do: refused(:config_error, error, destination, now)

  def plan({:blocked, _reason}, error, destination, _batch, now) do
    destination
    |> failed_halt(:blocked_address, error, now)
    |> Map.put(:cursor, %{next_attempt_at: nil})
  end

  @doc """
  Halts `destination` with `halted_reason` and `state_reason`: Failing at
  once, the `audit_stream_failing` event when this is the move into Failing,
  and no follow-up. The cursor is left to the caller.
  """
  @spec halt(Destination.t(), atom(), String.t(), DateTime.t()) :: %{
          cursor: map(),
          destination: map(),
          audit: {:failing, atom()} | nil,
          follow_up_at: nil
        }
  def halt(%Destination{} = destination, halted_reason, state_reason, now) do
    %{
      cursor: %{},
      destination: %{
        state: :failing,
        state_reason: state_reason,
        halted_reason: halted_reason,
        failing_since: destination.failing_since || DateTime.truncate(now, :second)
      },
      audit: failing_audit(destination, halted_reason),
      follow_up_at: nil
    }
  end

  # A halt caused by a failed send also counts the failure.
  defp failed_halt(destination, halted_reason, error, now) do
    destination
    |> halt(halted_reason, error, now)
    |> put_in([:destination, :consecutive_failures], destination.consecutive_failures + 1)
  end

  # Unauthorized and configuration errors: Failing at once, still tried at the
  # capped interval so it recovers by itself once fixed at the tool's end.
  defp refused(reason, error, destination, now) do
    due = DateTime.add(now, capped_delay(nil), :second)

    %{
      cursor: %{next_attempt_at: due},
      destination: failing_now(destination, error, now),
      audit: failing_audit(destination, reason),
      follow_up_at: due
    }
  end

  # A retryable failure: Retrying, or Failing once the run of failures has
  # lasted 30 minutes.
  defp failure(destination, error, now) do
    since = destination.failing_since || DateTime.truncate(now, :second)
    failing? = destination.state == :failing or DateTime.diff(now, since) >= @failing_after

    status = %{
      state: if(failing?, do: :failing, else: :retrying),
      state_reason: error,
      failing_since: since,
      consecutive_failures: destination.consecutive_failures + 1
    }

    {status, if(failing?, do: failing_audit(destination, :no_success))}
  end

  defp failing_now(destination, error, now) do
    %{
      state: :failing,
      state_reason: error,
      failing_since: destination.failing_since || DateTime.truncate(now, :second),
      consecutive_failures: destination.consecutive_failures + 1
    }
  end

  defp failing_audit(%Destination{state: :failing}, _reason), do: nil
  defp failing_audit(_destination, reason), do: {:failing, reason}

  defp cleared_pending do
    %{
      pending_batch_id: nil,
      pending_first_txid: nil,
      pending_first_id: nil,
      pending_last_txid: nil,
      pending_last_id: nil,
      pending_attempts: 0,
      pending_filter_version: nil,
      pending_organization_id: nil,
      pending_organization_name: nil,
      next_attempt_at: nil
    }
  end

  @doc "The cursor fields that discard a pending batch."
  @spec cleared_pending_attrs() :: map()
  def cleared_pending_attrs, do: cleared_pending()
end
