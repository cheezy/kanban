defmodule Kanban.AuditStream do
  @moduledoc """
  Audit log streaming destinations: the only way an org-admin lists, adds,
  changes, pauses, resumes, deletes or rotates one
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §4, §5, §8.5, §12).

  ## Access

  Every function takes the caller's `%Kanban.Accounts.Scope{}` first and
  re-reads from the database that its user is an enabled org-admin; the role
  cached in the session is never trusted. The Organization is the one the
  user belongs to, read from their membership, so a caller can never name
  another. A member, a disabled org-admin, a site admin (D8) or a missing
  scope gets `{:error, :unauthorized}`, and a destination of another
  Organization, or one deleted since it was loaded, `{:error, :not_found}`.
  Every write checks again inside its transaction, under the Organization row
  lock that removing, demoting, disabling or deleting an org-admin also takes,
  so a write never commits under rights revoked while it waited for a lock.
  `change_destination/3` is the exception: a form helper that reads nothing
  from the database, so it checks nothing.

  ## Secrets

  URLs, credentials and signing secrets are encrypted at rest and never
  appear in an audit event, which names a destination by its id, kind, name
  and host only (§12.2). An HTTPS destination's signing secret is generated
  here (`assec_` and 32 random bytes, base64url) and its plaintext is returned
  once, by `create_destination/3` and `rotate_signing_secret/2`. Every
  destination these functions return, and every error changeset, carries
  neither the signing secret nor the previous one.

  A secret written under a lost or replaced `ENCRYPTION_KEY` loads as
  `:unreadable` (D17). `update_destination/4` refuses to keep an unreadable
  URL or credential until a new value is given, and clears a
  `credentials_unreadable` halt once nothing the destination needs is
  unreadable; `rotate_signing_secret/2` replaces an unreadable signing secret.

  ## Start points

  A new destination's cursor starts where `start_from` says (§8.5): `"now"`
  (the default) at the horizon read inside the creating transaction, so the
  destination's own created event is its first; `"24h"` and `"7d"` (and
  Datadog's `"17h"`) at the start of the log with `not_before` at the start
  of the window; `"all"` at the start of the log. Datadog offers only `"now"`
  and `"17h"`.

  The write logic lives in `Kanban.AuditStream.Destinations`, the audit
  events it records in `Kanban.AuditStream.DestinationEvents`, and its URL
  checks in `Kanban.AuditStream.Reachability`, and its signing secrets in
  `Kanban.AuditStream.SigningSecrets`.

  ## Status, tests and halted batches

  `destination_status/3`, `list_destinations_with_status/2`,
  `list_attempts/2` and `pending_batch_summary/2` read a destination's
  delivery (`Kanban.AuditStream.Status`); `list_gaps/2` and `dismiss_gap/2`
  read and dismiss the gaps it will never fill (`Kanban.AuditStream.Gaps`); `send_test_event/3` sends a
  synthetic event and returns only a coarse class
  (`Kanban.AuditStream.TestEvent`); `retry_now/2` and `skip_batch/2` are the
  two ways out of a `rejected_batch` halt, both under the destination's lease
  (`Kanban.AuditStream.BatchActions`). Each authorizes as above.

  ## For the workers

  `enqueue_dispatch/2`, `due_for_dispatch/2`, `measure_lag/3`,
  `audit_due_gaps/1` and `prune_attempts/1` serve the delivery workers and
  take no scope. The
  sweep's queries (`Kanban.AuditStream.Sweep`) select only the fields they
  need, so a destination's secrets are never decrypted every minute.

  ## For operators

  `reseed_cursors/1` re-seeds every destination's cursor after a logical
  database move (`Kanban.AuditStream.Reseed`, §8.8). It takes no scope:
  only `Kanban.Release.reseed_audit_stream_cursors/1`, run from a release
  console, calls it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.BatchActions
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Reseed
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.AuditStream.Status
  alias Kanban.AuditStream.Sweep
  alias Kanban.AuditStream.TestEvent
  alias Kanban.Repo

  @attempts_kept 200
  @attempt_days 7

  @doc """
  The Organization's destinations, oldest first, or `{:error,
  :unauthorized}`. An Organization with none gets `{:ok, []}`.
  """
  @spec list_destinations(Scope.t() | nil) :: {:ok, [Destination.t()]} | {:error, :unauthorized}
  def list_destinations(scope) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope) do
      query =
        from(d in Destination,
          where: d.organization_id == ^organization_id,
          order_by: [asc: d.inserted_at, asc: d.id]
        )

      {:ok, query |> Repo.all() |> SigningSecrets.conceal()}
    end
  end

  @doc "The Organization's destination `id`."
  @spec get_destination(Scope.t() | nil, term()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def get_destination(scope, id) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope) do
      organization_id |> Destinations.fetch(id) |> SigningSecrets.conceal()
    end
  end

  @doc """
  A changeset for the destination form, prepared as a save would prepare it:
  for a saved destination the kind and `enabled` are ignored and a blank URL
  or credential keeps the stored one. It reads nothing from the database and
  so does not authorize; saving does.
  """
  @spec change_destination(Scope.t() | nil, Destination.t(), map()) :: Changeset.t()
  def change_destination(_scope, %Destination{} = destination \\ %Destination{}, attrs \\ %{}),
    do: Destinations.change(destination, attrs)

  @doc """
  Adds a destination to the caller's Organization, with its cursor at
  `start_from`, and records `audit_stream_destination_created` in the same
  transaction.

  Returns `{:ok, {destination, signing_secret}}`: `signing_secret` is the
  plaintext of an HTTPS destination's new signing secret, the only copy the
  caller gets, and `nil` for Splunk and Datadog. The Organization's row is
  locked while its destinations are counted, so two creates can't pass
  `Destination.max_destinations/0`; the one past it gets `{:error,
  :limit_reached}`. A Splunk or HTTPS URL `Kanban.Webhooks.UrlGuard` refuses
  is an error on `:url`, and a start point the kind does not offer an error
  on `:start_from`. `opts` are passed to `UrlGuard.check/2` over the
  configured resolver.
  """
  @spec create_destination(Scope.t() | nil, map(), keyword()) ::
          {:ok, {Destination.t(), String.t() | nil}}
          | {:error, :unauthorized | :not_found | :limit_reached | Changeset.t()}
  def create_destination(scope, attrs, opts \\ []), do: Destinations.create(scope, attrs, opts)

  @doc """
  Changes a destination's name, URL, credential, settings, personal-data
  choice or excluded actions, and records `audit_stream_destination_updated`
  with the names of the fields that changed. A save that changes none records
  nothing.

  The save is optimistically locked on `lock_version`: a destination loaded
  before another save gets `{:error, changeset}` with an error on `:id`. The
  kind never changes, and `enabled` changes only through
  `pause_destination/2` and `resume_destination/2`. A blank URL or credential
  keeps the stored value, unless that value is unreadable, which is an error
  on the field until a new value is given. A changed URL is checked again with
  `UrlGuard.check/2` and clears a `blocked_address` halt; a save that leaves
  nothing the destination needs unreadable clears a `credentials_unreadable`
  halt. A change to `excluded_actions` or `include_personal_data` increases
  `filter_version` by one (D16); on a destination halted with
  `rejected_batch` it also clears the halt and queues a dispatch run, as
  `retry_now/2` does, since the rejected events may no longer be in the
  batch the next run cuts. Any other halt stays.
  """
  @spec update_destination(Scope.t() | nil, Destination.t(), map(), keyword()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found | Changeset.t()}
  def update_destination(scope, %Destination{} = destination, attrs, opts \\ []),
    do: Destinations.update(scope, destination, attrs, opts)

  @doc "Pauses a destination and records `audit_stream_destination_paused`."
  @spec pause_destination(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def pause_destination(scope, %Destination{} = destination),
    do: Destinations.set_enabled(scope, destination, false)

  @doc "Resumes a destination and records `audit_stream_destination_resumed`."
  @spec resume_destination(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def resume_destination(scope, %Destination{} = destination),
    do: Destinations.set_enabled(scope, destination, true)

  @doc """
  Records `audit_stream_destination_deleted`, then deletes the destination
  with its cursor, attempts and gaps.
  """
  @spec delete_destination(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def delete_destination(scope, %Destination{} = destination),
    do: Destinations.delete(scope, destination)

  @doc """
  Gives an HTTPS destination a new signing secret and records
  `audit_stream_signing_secret_rotated`. Returns `{:ok, {destination,
  signing_secret}}` with the new plaintext, shown once.

  A readable current secret becomes the previous secret, still valid for 24
  hours. An unreadable one can't sign, so it is replaced with no overlap and
  any previous secret is dropped; a `credentials_unreadable` halt is cleared
  when nothing else the destination needs is unreadable. Another kind gets
  `{:error, :not_https}`, and a destination loaded before another save
  `{:error, changeset}` with an error on `:id`.

  Only one previous secret is kept, so a readable current secret can't be
  rotated again until the last rotation's 24 hours have ended: until then
  the call returns `{:error, {:rotation_overlap, previous_secret_expires_at}}`,
  the time it can rotate again, and changes and records nothing. The check is
  made under the destination's row lock, after the rights check. Replacing an
  unreadable current secret is never refused.
  """
  @spec rotate_signing_secret(Scope.t() | nil, Destination.t()) ::
          {:ok, {Destination.t(), String.t()}}
          | {:error,
             :unauthorized
             | :not_found
             | :not_https
             | {:rotation_overlap, DateTime.t()}
             | Changeset.t()}
  def rotate_signing_secret(scope, %Destination{} = destination),
    do: Destinations.rotate(scope, destination)

  @doc """
  The destination's status: `state` (`:paused`, `:needs_attention`,
  `:healthy`, `:retrying` or `:failing`), `state_reason`, `halted_reason`,
  `last_success_at` and `lag`, whose waiting events include those above the
  horizon. See `Kanban.AuditStream.Status`. `opts` take `:horizon` and
  `:now`, for tests.
  """
  @spec destination_status(Scope.t() | nil, Destination.t(), keyword()) ::
          {:ok, Status.t()} | {:error, :unauthorized | :not_found}
  def destination_status(scope, %Destination{} = destination, opts \\ []),
    do: Status.destination_status(scope, destination, opts)

  @doc """
  The Organization's destinations, oldest first, each as `%{destination:
  destination, status: status}` (see `destination_status/3`).
  """
  @spec list_destinations_with_status(Scope.t() | nil, keyword()) ::
          {:ok, [%{destination: Destination.t(), status: Status.t()}]}
          | {:error, :unauthorized}
  def list_destinations_with_status(scope, opts \\ []),
    do: Status.list_destinations_with_status(scope, opts)

  @doc "The destination's newest 50 attempts, newest first."
  @spec list_attempts(Scope.t() | nil, Destination.t()) ::
          {:ok, [Attempt.t()]} | {:error, :unauthorized | :not_found}
  def list_attempts(scope, %Destination{} = destination),
    do: Status.list_attempts(scope, destination)

  @doc """
  The destination's gaps, open and dismissed, newest first: the events it
  will never receive, because retention deleted them first or they were too
  old for its kind.
  """
  @spec list_gaps(Scope.t() | nil, Destination.t()) ::
          {:ok, [Gap.t()]} | {:error, :unauthorized | :not_found}
  def list_gaps(scope, %Destination{} = destination), do: Gaps.list_gaps(scope, destination)

  @doc """
  Dismisses a gap and records `audit_stream_gap_dismissed`. A later loss
  then opens a new gap. Dismissing a dismissed gap records nothing.
  """
  @spec dismiss_gap(Scope.t() | nil, Gap.t()) ::
          {:ok, Gap.t()} | {:error, :unauthorized | :not_found}
  def dismiss_gap(scope, %Gap{} = gap), do: Gaps.dismiss_gap(scope, gap)

  @doc """
  For the minute sweep: records `audit_stream_gap` for each open gap that
  grew since its last one, once a day has passed since it. Returns how many.
  """
  @spec audit_due_gaps(DateTime.t()) :: non_neg_integer()
  def audit_due_gaps(%DateTime{} = now), do: Gaps.audit_due(now)

  @doc """
  For an operator after a logical database move: records the events each
  destination had not received and can no longer be sent as a
  `database_move` gap, sets every cursor to `(0, 0)` from its last delivered
  event's time with the restored rows left out, discards pending batches,
  clears `txid_reset` halts and records one `audit_stream_cursors_reseeded`
  event per Organization. `Kanban.AuditStream.Reseed.run/1` documents the
  options and the counts it returns.
  """
  @spec reseed_cursors(keyword()) :: {:ok, Reseed.counts()}
  def reseed_cursors(opts \\ []), do: Reseed.run(opts)

  @doc """
  For a destination halted with `rejected_batch`, the batch it is stuck on:
  its event count, first and last event ids and times, and the
  destination's last answer as Stride classified it; `{:ok, nil}` for any
  other destination.
  """
  @spec pending_batch_summary(Scope.t() | nil, Destination.t()) ::
          {:ok, Status.pending_batch() | nil} | {:error, :unauthorized | :not_found}
  def pending_batch_summary(scope, %Destination{} = destination),
    do: Status.pending_batch_summary(scope, destination)

  @doc """
  Sends a synthetic `stride.audit.v1` event with the action
  `audit_stream_test_sent` and no real audit data through the destination's
  adapter, and records `audit_stream_test_sent` with its outcome. It never
  touches the cursor, the state or the attempts.

  Returns `{:ok, class}`, a coarse class only: `:delivered`,
  `:could_not_connect` (a refused connection, a timeout, a host that does
  not resolve or a blocked address), `:certificate_invalid`,
  `:credentials_refused` or `{:http_error, status}`; never a body or a
  transport detail (§12.5). Limited to 10 an hour per Organization
  (`{:error, {:rate_limited, retry_after_ms}}`); a destination whose secrets
  can't be read gets `{:error, :credentials_unreadable}`. See
  `Kanban.AuditStream.TestEvent`.
  """
  @spec send_test_event(Scope.t() | nil, Destination.t(), keyword()) ::
          {:ok, TestEvent.class()}
          | {:error,
             :unauthorized
             | :not_found
             | :credentials_unreadable
             | {:rate_limited, non_neg_integer()}}
  def send_test_event(scope, %Destination{} = destination, opts \\ []),
    do: TestEvent.send_test(scope, destination, opts)

  @doc """
  **Retry now**: clears a `rejected_batch` halt, resets the pending batch's
  `pending_attempts` and `next_attempt_at`, and queues a dispatch run, under
  the destination's lease. Any other destination gets `{:error,
  :not_rejected_batch}`, and one whose lease a run holds `{:error, :busy}`.
  """
  @spec retry_now(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, BatchActions.error()}
  def retry_now(scope, %Destination{} = destination),
    do: BatchActions.retry_now(scope, destination)

  @doc """
  **Skip this batch**: for a destination halted with `rejected_batch` only,
  under its lease, records an attempt with outcome `skipped` and
  `audit_stream_batch_skipped`, moves the cursor past exactly the pending
  batch, discards it, clears the halt and queues a dispatch run. Any other
  destination, including a configuration error, gets `{:error,
  :not_rejected_batch}`, and one whose lease a run holds `{:error, :busy}`.
  """
  @spec skip_batch(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, BatchActions.error()}
  def skip_batch(scope, %Destination{} = destination),
    do: BatchActions.skip_batch(scope, destination)

  @doc """
  Queues a `Kanban.AuditStream.DispatchWorker` run for the destination
  `destination_id`. For the worker and the sweep only, so it takes no scope
  and checks nothing: the run itself ends at once for a paused, halted or
  deleted destination. `opts` are `Oban.Worker.new/2` options, such as
  `:scheduled_at`, which defaults to now. A run already queued for the
  destination is kept, and returned with `conflict?: true`, rather than
  queued twice; when that run is scheduled, it moves to this one's
  `scheduled_at`.
  """
  @spec enqueue_dispatch(integer(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_dispatch(destination_id, opts \\ []) when is_integer(destination_id) do
    opts = Keyword.put_new_lazy(opts, :scheduled_at, &DateTime.utc_now/0)
    destination_id |> DispatchWorker.job(opts) |> Oban.insert()
  end

  @doc """
  The ids of the destinations the minute sweep queues a run for at `now`.
  Each is not halted (`halted_reason` is nil), not leased (no run holds a
  lease that is still live at `now`) and either enabled, due
  (`next_attempt_at` nil or not after `now`) and with an event waiting below
  the horizon (`Kanban.AuditStream.Reader.next_waiting_at/3`), or, paused or
  backed off too, with a cursor at or past this server's next transaction
  id. The second is a logical database move (§8.8): after one, no new event
  sorts after a caught-up cursor, so only this check queues the run that
  halts it with `txid_reset`, and once this server's transaction ids pass
  the cursor the move can no longer be seen. A destination halted for
  another reason keeps that halt for a person; the re-seed covers it. A run that holds the
  lease queues its own follow-up; a job queued for it now would only snooze
  in a unique state and make that follow-up a duplicate, delaying the next
  send by up to a minute. A lease left by a run that crashed expires within
  60 seconds, and the next sweep picks the destination up. For the sweep
  only, so it takes no scope. `opts` takes `:horizon`, for tests.
  """
  @spec due_for_dispatch(DateTime.t(), keyword()) :: [integer()]
  def due_for_dispatch(%DateTime{} = now, opts \\ []), do: Sweep.due_for_dispatch(now, opts)

  @doc """
  The lag of the enabled destinations whose 15-minute slot is `minute`
  (`id` modulo 15 equals `minute` modulo 15), so each is measured once
  every 15 minutes with no stored state (§13.1). Halted destinations are
  measured, since their lag is what grows; paused ones are not.

  Each is `%{kind, lag_seconds, events_waiting, events_above_horizon}`, from
  `Kanban.AuditStream.Reader.waiting_counts/3` at `now`: `lag_seconds` is
  the age of the oldest waiting event in whole seconds, or 0 when none is
  waiting. A held horizon therefore shows as waiting events and a growing
  lag, never as zero. `opts` takes `:horizon`, for tests.
  """
  @spec measure_lag(non_neg_integer(), DateTime.t(), keyword()) :: [map()]
  def measure_lag(minute, %DateTime{} = now, opts \\ []) when is_integer(minute),
    do: Sweep.measure_lag(minute, now, opts)

  @doc """
  Deletes the attempts the hourly prune does not keep (§8.7): those that
  started more than 7 days before `now`, and all but the newest 200 of each
  destination. Gaps are another table and are never touched. Returns how
  many attempts were deleted.
  """
  @spec prune_attempts(DateTime.t()) :: non_neg_integer()
  def prune_attempts(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@attempt_days * 86_400, :second)
    {old, _} = from(a in Attempt, where: a.started_at < ^cutoff) |> Repo.delete_all()

    ranked =
      from(a in Attempt,
        select: %{
          id: a.id,
          rank:
            over(row_number(),
              partition_by: a.destination_id,
              order_by: [desc: a.started_at, desc: a.id]
            )
        }
      )

    extra =
      from(a in Attempt,
        join: r in subquery(ranked),
        on: r.id == a.id,
        where: r.rank > ^@attempts_kept
      )

    {beyond, _} = Repo.delete_all(extra)
    old + beyond
  end
end
