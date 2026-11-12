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
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.Repo

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
  `filter_version` by one (D16).
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
  """
  @spec rotate_signing_secret(Scope.t() | nil, Destination.t()) ::
          {:ok, {Destination.t(), String.t()}}
          | {:error, :unauthorized | :not_found | :not_https | Changeset.t()}
  def rotate_signing_secret(scope, %Destination{} = destination),
    do: Destinations.rotate(scope, destination)

  @doc """
  Queues a `Kanban.AuditStream.DispatchWorker` run for the destination
  `destination_id`. For the worker and the sweep only, so it takes no scope
  and checks nothing: the run itself ends at once for a paused, halted or
  deleted destination. `opts` are `Oban.Worker.new/2` options, such as
  `:scheduled_at`. A run already queued for the destination is kept, and
  returned with `conflict?: true`, rather than queued twice.
  """
  @spec enqueue_dispatch(integer(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_dispatch(destination_id, opts \\ []) when is_integer(destination_id),
    do: destination_id |> DispatchWorker.job(opts) |> Oban.insert()
end
