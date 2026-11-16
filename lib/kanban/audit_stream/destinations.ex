defmodule Kanban.AuditStream.Destinations do
  @moduledoc """
  The write logic behind `Kanban.AuditStream`
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §4, §5, §8.5, §12.2, §12.3).

  Every function authorizes the actor first, finds a destination only within
  the actor's own Organization, and checks again inside its transaction once
  it holds the Organization row lock and the destination's.

  Each change records its audit event inside the transaction that makes it,
  so the event never commits without its change, and every destination,
  including one just created, receives it (§12.3). `Kanban.AuditLog.event/2`
  inserts under a savepoint and logs rather than raises when that insert
  fails, so a failed audit insert never blocks the change it describes.

  `Kanban.AuditStream.Destinations.Access` authorizes the actor and takes the
  locks, and `Kanban.AuditStream.Destinations.UpdateChangeset` builds an
  edit's changeset; this module runs each write's transaction, records its
  audit event and emails the org-admins.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Destinations.Access
  alias Kanban.AuditStream.Destinations.UpdateChangeset
  alias Kanban.AuditStream.Reachability
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.AuditStream.StartPoint
  alias Kanban.Notifications
  alias Kanban.Notifications.AuditStreamAlerts
  alias Kanban.Repo

  @doc """
  Re-reads the scope's user from the database and returns
  `{:ok, actor, organization_id}` when they are an enabled org-admin of their
  Organization, else `{:error, :unauthorized}`. A site admin is not an
  org-admin, so is refused (D8).
  """
  @spec authorize(Scope.t() | nil) :: {:ok, User.t(), pos_integer()} | {:error, :unauthorized}
  defdelegate authorize(scope), to: Access

  @doc """
  The Organization's destination `id`, or `{:error, :not_found}`. With
  `lock: true` the row is locked `FOR UPDATE`.
  """
  @spec fetch(pos_integer(), term(), keyword()) :: {:ok, Destination.t()} | {:error, :not_found}
  defdelegate fetch(organization_id, id, opts \\ []), to: Access

  @doc """
  Inside a transaction: locks the Organization row, then the destination's
  (`FOR UPDATE`), and reads the actor's rights again, so a revocation that
  committed during either wait is seen. Every path that takes both locks
  takes them in that order. A revoked caller gets `{:error, :unauthorized}`
  before being told whether the destination still exists.
  """
  @spec fetch_authorized(User.t(), pos_integer(), term()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  defdelegate fetch_authorized(actor, organization_id, id), to: Access

  @doc "A changeset for the destination form. Reads nothing from the database."
  @spec change(Destination.t(), map()) :: Changeset.t()
  def change(%Destination{id: nil} = destination, attrs) do
    Destination.changeset(destination, attrs |> Map.new() |> drop_keys([:start_from]))
  end

  def change(%Destination{} = destination, attrs),
    do: Destination.changeset(destination, UpdateChangeset.attrs(attrs))

  @doc """
  Creates a destination and its cursor, returning `{:ok, {destination,
  signing_secret}}`. `signing_secret` is the plaintext of a new HTTPS
  destination's signing secret, the only copy the caller gets, and `nil` for
  the other kinds.
  """
  @spec create(Scope.t() | nil, map(), keyword()) ::
          {:ok, {Destination.t(), String.t() | nil}}
          | {:error, :unauthorized | :not_found | :limit_reached | Changeset.t()}
  def create(scope, attrs, opts) do
    with {:ok, actor, organization_id} <- authorize(scope),
         {:ok, changeset, start_from} <- creation_changeset(actor, organization_id, attrs, opts) do
      fn -> insert_with_cursor(changeset, actor, start_from) end
      |> Repo.transact()
      |> SigningSecrets.reveal()
    end
  end

  @doc """
  Updates the destination's editable fields under an optimistic lock on
  `lock_version`. See `Kanban.AuditStream.update_destination/4`.
  """
  @spec update(Scope.t() | nil, Destination.t(), map(), keyword()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found | Changeset.t()}
  def update(scope, %Destination{id: id, lock_version: lock_version}, attrs, opts) do
    attrs = UpdateChangeset.attrs(attrs)

    with {:ok, actor, organization_id} <- authorize(scope) do
      # The new URL is looked up before the transaction, so the destination
      # row is never locked during a DNS lookup.
      reachability = Reachability.lookup(attrs, opts)
      locked = {organization_id, id, lock_version}

      fn -> update_locked(locked, attrs, reachability, actor) end
      |> Repo.transact()
      |> SigningSecrets.conceal()
    end
  end

  @doc "Sets `enabled` and records the destination as paused or resumed."
  @spec set_enabled(Scope.t() | nil, Destination.t(), boolean()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def set_enabled(scope, %Destination{id: id}, enabled) when is_boolean(enabled) do
    with {:ok, actor, organization_id} <- authorize(scope) do
      fn -> toggle_locked(organization_id, id, enabled, actor) end
      |> Repo.transact()
      |> SigningSecrets.conceal()
    end
  end

  @doc """
  Records the destination as deleted, then deletes it; the database cascade
  removes its cursor, attempts and gaps.
  """
  @spec delete(Scope.t() | nil, Destination.t()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def delete(scope, %Destination{id: id}) do
    with {:ok, actor, organization_id} <- authorize(scope) do
      fn -> delete_locked(organization_id, id, actor) end
      |> Repo.transact()
      |> SigningSecrets.conceal()
    end
  end

  @doc """
  Replaces an HTTPS destination's signing secret. See
  `Kanban.AuditStream.rotate_signing_secret/2`.
  """
  @spec rotate(Scope.t() | nil, Destination.t()) ::
          {:ok, {Destination.t(), String.t()}}
          | {:error,
             :unauthorized
             | :not_found
             | :not_https
             | {:rotation_overlap, DateTime.t()}
             | Changeset.t()}
  def rotate(scope, %Destination{id: id, lock_version: lock_version}) do
    with {:ok, actor, organization_id} <- authorize(scope) do
      fn -> rotate_locked(organization_id, id, lock_version, actor) end
      |> Repo.transact()
      |> SigningSecrets.reveal()
    end
  end

  # --- create -------------------------------------------------------------------

  # Everything that can be checked before the transaction is, so the
  # Organization row is never locked during a DNS lookup.
  defp creation_changeset(actor, organization_id, attrs, opts) do
    {start_from, attrs} = StartPoint.pop(attrs)

    changeset =
      %Destination{organization_id: organization_id, created_by_id: actor.id}
      |> Destination.changeset(drop_keys(attrs, [:enabled]))
      |> StartPoint.validate(start_from)
      |> Reachability.check(opts)
      |> put_new_signing_secret()

    if changeset.valid?,
      do: {:ok, changeset, start_from},
      else: {:error, %{changeset | action: :insert}}
  end

  # The horizon is read after the Organization lock and before the insert,
  # inside the creating transaction, so the created event (recorded last, by
  # this transaction) sorts after a from-now cursor (§8.5).
  defp insert_with_cursor(changeset, actor, start_from) do
    organization_id = Changeset.get_field(changeset, :organization_id)

    with :ok <- Access.authorize_locked(actor, organization_id),
         :ok <- check_limit(organization_id),
         horizon = read_horizon(),
         {:ok, destination} <- Repo.insert(changeset),
         {:ok, _cursor} <- insert_cursor(destination, start_from, horizon),
         _event = DestinationEvents.created(destination, actor, start_from),
         :ok <- email(:created, destination, actor, %{start_from: start_from}) do
      {:ok, destination}
    end
  end

  defp put_new_signing_secret(%Changeset{valid?: true} = changeset) do
    case Changeset.get_field(changeset, :kind) do
      :https -> Changeset.put_change(changeset, :signing_secret, SigningSecrets.generate())
      _kind -> changeset
    end
  end

  defp put_new_signing_secret(changeset), do: changeset

  defp check_limit(organization_id) do
    count =
      from(d in Destination, where: d.organization_id == ^organization_id)
      |> Repo.aggregate(:count)

    if count < Destination.max_destinations(), do: :ok, else: {:error, :limit_reached}
  end

  defp read_horizon do
    %{rows: [[horizon]]} =
      Repo.query!("SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint")

    horizon
  end

  defp insert_cursor(destination, start_from, horizon) do
    %Cursor{destination_id: destination.id}
    |> Cursor.changeset(StartPoint.cursor_attrs(start_from, horizon))
    |> Repo.insert()
  end

  # --- update -------------------------------------------------------------------

  defp update_locked({organization_id, id, lock_version}, attrs, reachability, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id) do
      fresh
      |> UpdateChangeset.build(lock_version, attrs, reachability)
      |> save_update(actor)
    end
  end

  # A save that changes no editable field records no event.
  defp save_update(changeset, actor) do
    changed = UpdateChangeset.changed_fields(changeset)
    emailed = AuditStreamAlerts.emailed_changes(changeset)

    with {:ok, destination} <- Repo.update(changeset, stale_error_field: :id),
         :ok <- requeue_rejected(changeset),
         :ok <- email_changes(destination, actor, emailed) do
      record_updated(destination, actor, changed)
      {:ok, destination}
    end
  end

  defp record_updated(_destination, _actor, []), do: :ok

  defp record_updated(destination, actor, changed),
    do: DestinationEvents.updated(destination, actor, Enum.map(changed, &Atom.to_string/1))

  # Only a change that decides where events go or what they carry is
  # emailed (§12.3), so renaming a destination is not.
  defp email_changes(_destination, _actor, []), do: :ok

  defp email_changes(destination, actor, emailed),
    do: email(:updated, destination, actor, %{changed: emailed})

  # A cleared rejected_batch halt queues a run in the same transaction, as
  # Retry now does; the sweep picks up every other cleared halt.
  defp requeue_rejected(%Changeset{data: %{halted_reason: :rejected_batch} = data} = changeset) do
    case Changeset.fetch_change(changeset, :halted_reason) do
      {:ok, nil} -> enqueue(data.id)
      _kept -> :ok
    end
  end

  defp requeue_rejected(_changeset), do: :ok

  defp enqueue(destination_id) do
    with {:ok, _job} <- Kanban.AuditStream.enqueue_dispatch(destination_id), do: :ok
  end

  # --- pause and resume ---------------------------------------------------------

  # Recorded on every call, even one that leaves enabled as it was; emailed
  # only when it pauses or resumes the destination.
  defp toggle_locked(organization_id, id, enabled, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id),
         {:ok, destination} <- fresh |> Changeset.change(enabled: enabled) |> Repo.update(),
         _event = DestinationEvents.enabled(destination, actor, enabled),
         :ok <- email_toggle(fresh.enabled, destination, actor) do
      {:ok, destination}
    end
  end

  defp email_toggle(enabled, %Destination{enabled: enabled}, _actor), do: :ok
  defp email_toggle(_was, %Destination{enabled: false} = d, actor), do: email(:paused, d, actor)
  defp email_toggle(_was, %Destination{enabled: true} = d, actor), do: email(:resumed, d, actor)

  # --- delete -------------------------------------------------------------------

  # The email's snapshot is taken while the row still exists.
  defp delete_locked(organization_id, id, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id),
         :ok <- email(:deleted, fresh, actor) do
      DestinationEvents.deleted(fresh, actor)
      Repo.delete(fresh)
    end
  end

  # --- rotate -------------------------------------------------------------------

  defp rotate_locked(organization_id, id, lock_version, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id),
         :ok <- require_https(fresh),
         :ok <- require_no_overlap(fresh),
         {:ok, destination} <-
           fresh |> rotation_changeset(lock_version) |> Repo.update(stale_error_field: :id) do
      DestinationEvents.rotated(destination, actor)
      {:ok, destination}
    end
  end

  defp require_https(%Destination{kind: :https}), do: :ok
  defp require_https(%Destination{}), do: {:error, :not_https}

  # Read from the locked row, after the rights check. An unreadable current
  # secret is replaced with no overlap, so it is never refused: that is how a
  # broken secret is repaired.
  defp require_no_overlap(%Destination{signing_secret: current} = fresh)
       when is_binary(current) do
    if SigningSecrets.in_overlap?(fresh, DateTime.utc_now()),
      do: {:error, {:rotation_overlap, fresh.previous_secret_expires_at}},
      else: :ok
  end

  defp require_no_overlap(%Destination{}), do: :ok

  defp rotation_changeset(fresh, lock_version) do
    attrs =
      fresh.signing_secret
      |> SigningSecrets.previous()
      |> Map.put(:signing_secret, SigningSecrets.generate())

    %{fresh | lock_version: lock_version}
    |> Destination.signing_secret_changeset(attrs)
    |> Changeset.optimistic_lock(:lock_version)
    |> UpdateChangeset.clear_halt(fresh)
  end

  # --- shared -------------------------------------------------------------------

  # The org-admin emails go in the change's own transaction, so a change that
  # rolls back emails nobody; a job that can't be inserted rolls it back.
  defp email(kind, destination, actor, details \\ %{}),
    do: Notifications.enqueue_audit_stream_email(kind, destination, actor, details)

  defp drop_keys(attrs, keys), do: Map.drop(attrs, keys ++ Enum.map(keys, &Atom.to_string/1))
end
