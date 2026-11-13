defmodule Kanban.AuditStream.Status do
  @moduledoc """
  What an org-admin sees of a destination's delivery: its status, its lag,
  its last attempts and the batch it is stuck on
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §10.2, §10.4, §13.1).

  Every function that takes a scope authorizes first with
  `Kanban.AuditStream.Destinations.authorize/1`, so only an enabled org-admin
  of the destination's Organization reads anything through them. `state/1`
  and `rejected_batch/2` take no scope and authorize nothing: they are for
  callers that have authorized already. All of them only read, so none takes
  a lock or the lease.

  ## Status

    * `state` - `:paused` when the destination is disabled, else
      `:needs_attention` when it is halted, else its own `:healthy`,
      `:retrying` or `:failing`;
    * `state_reason`, `halted_reason` and `last_success_at` - as stored;
    * `lag` - from `Kanban.AuditStream.Reader.waiting_counts/3`: the events
      waiting after the cursor, those of them still above the horizon, the
      time of the oldest and its age in whole seconds. Events held above the
      horizon count as waiting, so a held horizon is never `up_to_date`.

  `opts` take `:horizon` and `:now`, for tests.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.PendingBatch
  alias Kanban.AuditStream.Reader
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.Repo

  @attempts_shown 50

  @type state :: :paused | :needs_attention | :healthy | :retrying | :failing

  @type lag :: %{
          events_waiting: non_neg_integer(),
          events_above_horizon: non_neg_integer(),
          oldest_waiting_at: DateTime.t() | nil,
          oldest_age_seconds: non_neg_integer() | nil,
          up_to_date: boolean()
        }

  @type t :: %{
          state: state(),
          state_reason: String.t() | nil,
          halted_reason: atom() | nil,
          last_success_at: DateTime.t() | nil,
          lag: lag()
        }

  @type pending_batch :: %{
          batch_id: Ecto.UUID.t(),
          events: non_neg_integer(),
          first_event_id: integer(),
          last_event_id: integer(),
          first_at: DateTime.t() | nil,
          last_at: DateTime.t() | nil,
          http_status: integer() | nil,
          error: String.t() | nil
        }

  @doc "The status of the Organization's destination. See the moduledoc."
  @spec destination_status(Scope.t() | nil, Destination.t(), keyword()) ::
          {:ok, t()} | {:error, :unauthorized | :not_found}
  def destination_status(scope, %Destination{id: id}, opts \\ []) do
    with {:ok, destination, cursor} <- load(scope, id) do
      {:ok, status(destination, cursor, opts)}
    end
  end

  @doc """
  The Organization's destinations, oldest first, each as `%{destination:
  destination, status: status}`.
  """
  @spec list_destinations_with_status(Scope.t() | nil, keyword()) ::
          {:ok, [%{destination: Destination.t(), status: t()}]} | {:error, :unauthorized}
  def list_destinations_with_status(scope, opts \\ []) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope) do
      query =
        from(d in Destination,
          join: c in Cursor,
          on: c.destination_id == d.id,
          where: d.organization_id == ^organization_id,
          order_by: [asc: d.inserted_at, asc: d.id],
          select: {d, c}
        )

      rows =
        for {destination, cursor} <- Repo.all(query) do
          %{
            destination: SigningSecrets.conceal(destination),
            status: status(destination, cursor, opts)
          }
        end

      {:ok, rows}
    end
  end

  @doc "The destination's newest 50 attempts, newest first."
  @spec list_attempts(Scope.t() | nil, Destination.t()) ::
          {:ok, [Attempt.t()]} | {:error, :unauthorized | :not_found}
  def list_attempts(scope, %Destination{id: id}) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope),
         {:ok, destination} <- Destinations.fetch(organization_id, id) do
      query =
        from(a in Attempt,
          where: a.destination_id == ^destination.id,
          order_by: [desc: a.started_at, desc: a.id],
          limit: @attempts_shown
        )

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  For a destination halted with `rejected_batch`, the batch it is stuck on:
  how many events it holds, their first and last ids and times, and the
  destination's last answer to it as Stride classified it (`http_status`
  and the attempt's own `error`, never the response body). `{:ok, nil}` for
  a destination not halted with `rejected_batch`, or with no pending batch.
  """
  @spec pending_batch_summary(Scope.t() | nil, Destination.t()) ::
          {:ok, pending_batch() | nil} | {:error, :unauthorized | :not_found}
  def pending_batch_summary(scope, %Destination{id: id}) do
    with {:ok, destination, cursor} <- load(scope, id) do
      {:ok, rejected_batch(destination, cursor)}
    end
  end

  @doc """
  The pending batch of `destination` at `cursor` when it is halted with
  `rejected_batch`, else nil. For `pending_batch_summary/2` and
  `Kanban.AuditStream.BatchActions`, which have authorized already.
  """
  @spec rejected_batch(Destination.t(), Cursor.t()) :: pending_batch() | nil
  def rejected_batch(
        %Destination{halted_reason: :rejected_batch} = destination,
        %Cursor{pending_batch_id: batch_id} = cursor
      )
      when is_binary(batch_id) do
    events = pending_events(destination, cursor)

    Map.merge(
      %{
        batch_id: batch_id,
        events: length(events),
        first_event_id: cursor.pending_first_id,
        last_event_id: cursor.pending_last_id,
        first_at: events |> List.first() |> inserted_at(),
        last_at: events |> List.last() |> inserted_at()
      },
      last_answer(destination.id, batch_id)
    )
  end

  def rejected_batch(_destination, _cursor), do: nil

  @doc "The state shown for `destination`: paused, needs attention, or its own."
  @spec state(Destination.t()) :: state()
  def state(%Destination{enabled: false}), do: :paused
  def state(%Destination{halted_reason: reason}) when not is_nil(reason), do: :needs_attention
  def state(%Destination{state: state}), do: state

  defp status(destination, cursor, opts) do
    %{
      state: state(destination),
      state_reason: destination.state_reason,
      halted_reason: destination.halted_reason,
      last_success_at: destination.last_success_at,
      lag: lag(destination, cursor, opts)
    }
  end

  defp lag(destination, cursor, opts) do
    filters = PendingBatch.filters(destination, cursor) ++ Keyword.take(opts, [:horizon])
    position = {cursor.last_txid, cursor.last_event_id}
    counts = Reader.waiting_counts(destination.organization_id, position, filters)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Map.merge(counts, %{
      oldest_age_seconds: age(counts.oldest_waiting_at, now),
      up_to_date: counts.events_waiting == 0
    })
  end

  defp age(nil, _now), do: nil
  defp age(oldest, now), do: max(DateTime.diff(now, oldest, :second), 0)

  defp load(scope, id) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope),
         {:ok, destination} <- Destinations.fetch(organization_id, id),
         %Cursor{} = cursor <- Repo.get(Cursor, destination.id) do
      {:ok, destination, cursor}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # The batch's events as the destination is sent them: its filters apply.
  defp pending_events(destination, cursor) do
    first = {cursor.pending_first_txid, cursor.pending_first_id}
    last = {cursor.pending_last_txid, cursor.pending_last_id}
    filters = PendingBatch.filters(destination, cursor)
    Reader.read_range(destination.organization_id, first, last, filters)
  end

  # The status and error of the destination's latest attempt at the batch.
  defp last_answer(destination_id, batch_id) do
    query =
      from(a in Attempt,
        where: a.destination_id == ^destination_id and a.batch_id == ^batch_id,
        order_by: [desc: a.started_at, desc: a.id],
        limit: 1,
        select: %{http_status: a.http_status, error: a.error}
      )

    Repo.one(query) || %{http_status: nil, error: nil}
  end

  defp inserted_at(nil), do: nil
  defp inserted_at(event), do: event.inserted_at
end
