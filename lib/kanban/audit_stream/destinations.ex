defmodule Kanban.AuditStream.Destinations do
  @moduledoc """
  The write logic behind `Kanban.AuditStream`
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §4, §5, §8.5, §12.2, §12.3).

  Every function authorizes first with `authorize/1`, which re-reads from the
  database that the scope's user is an enabled org-admin and finds their
  Organization from their own membership, never from the session or the
  caller. A destination is then looked up by its id and that Organization, so
  another Organization's destination is `:not_found`.

  Every write checks again inside its transaction, once it holds the
  Organization row lock and the destination's, so a revocation that
  committed while it waited for either lock refuses it. Removing, demoting,
  disabling or deleting an org-admin takes the Organization row lock first
  (see `Kanban.Organizations.MembershipWrites`), so one that has not committed
  by the check waits until the write has.

  Each change records its audit event inside the transaction that makes it,
  so the event never commits without its change, and every destination,
  including one just created, receives it (§12.3). `Kanban.AuditLog.event/2`
  inserts under a savepoint and logs rather than raises when that insert
  fails, so a failed audit insert never blocks the change it describes.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Reachability
  alias Kanban.AuditStream.SigningSecrets
  alias Kanban.AuditStream.StartPoint
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  # The fields an org-admin edits, in the order `changed` lists them.
  @editable_fields [
    :name,
    :url,
    :credential,
    :settings,
    :include_personal_data,
    :excluded_actions
  ]

  # A change to either changes which events, or what content, a batch
  # carries, so it increases filter_version (D16).
  @filter_fields [:excluded_actions, :include_personal_data]

  # The secrets an org-admin types in, which must be entered again when they
  # can no longer be read (D17).
  @entered_secrets [:url, :credential]

  @doc """
  Re-reads the scope's user from the database and returns
  `{:ok, actor, organization_id}` when they are an enabled org-admin of their
  Organization, else `{:error, :unauthorized}`. A site admin is not an
  org-admin, so is refused (D8).
  """
  @spec authorize(Scope.t() | nil) :: {:ok, User.t(), pos_integer()} | {:error, :unauthorized}
  def authorize(%Scope{user: %User{id: id}}) do
    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         %OrganizationMember{organization_id: organization_id} <-
           Organizations.get_membership(actor),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, actor, organization_id}
    else
      _refused -> {:error, :unauthorized}
    end
  end

  def authorize(_scope), do: {:error, :unauthorized}

  @doc """
  The Organization's destination `id`, or `{:error, :not_found}`. With
  `lock: true` the row is locked `FOR UPDATE`.
  """
  @spec fetch(pos_integer(), term(), keyword()) :: {:ok, Destination.t()} | {:error, :not_found}
  def fetch(organization_id, id, opts \\ []) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) -> organization_id |> destination_query(id, opts) |> one()
      _invalid -> {:error, :not_found}
    end
  end

  @doc "A changeset for the destination form. Reads nothing from the database."
  @spec change(Destination.t(), map()) :: Changeset.t()
  def change(%Destination{id: nil} = destination, attrs) do
    Destination.changeset(destination, attrs |> Map.new() |> drop_keys([:start_from]))
  end

  def change(%Destination{} = destination, attrs),
    do: Destination.changeset(destination, update_attrs(attrs))

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
    attrs = update_attrs(attrs)

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

    with :ok <- authorize_locked(actor, organization_id),
         :ok <- check_limit(organization_id),
         horizon = read_horizon(),
         {:ok, destination} <- Repo.insert(changeset),
         {:ok, _cursor} <- insert_cursor(destination, start_from, horizon) do
      DestinationEvents.created(destination, actor, start_from)
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

  # The check authorize/1 made, made again once the Organization row is
  # locked. Two creates for one Organization also queue on that lock, so the
  # second counts the first's committed destination.
  defp authorize_locked(%User{} = actor, organization_id) do
    with :ok <- lock_organization(organization_id),
         do: still_org_admin(actor, organization_id)
  end

  @doc """
  Inside a transaction: locks the Organization row, then the destination's
  (`FOR UPDATE`), and reads the actor's rights again, so a revocation that
  committed during either wait is seen. Every path that takes both locks
  takes them in that order. A revoked caller gets `{:error, :unauthorized}`
  before being told whether the destination still exists.
  """
  @spec fetch_authorized(User.t(), pos_integer(), term()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def fetch_authorized(%User{} = actor, organization_id, id) do
    with :ok <- lock_organization(organization_id),
         fetched = fetch(organization_id, id, lock: true),
         :ok <- still_org_admin(actor, organization_id),
         do: fetched
  end

  defp still_org_admin(actor, organization_id) do
    if Organizations.org_admin?(actor, organization_id), do: :ok, else: {:error, :unauthorized}
  end

  defp lock_organization(organization_id) do
    query =
      from(o in Organization, where: o.id == ^organization_id, select: o.id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

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
      |> update_changeset(lock_version, attrs, reachability)
      |> save_update(actor)
    end
  end

  # The data is the row read under lock, with the caller's lock_version, so a
  # form loaded before another save is refused as stale.
  defp update_changeset(fresh, lock_version, attrs, reachability) do
    %{fresh | lock_version: lock_version}
    |> Destination.changeset(attrs)
    |> Changeset.optimistic_lock(:lock_version)
    |> require_current(fresh)
    |> require_readable(fresh)
    |> drop_reordered_actions(fresh)
    |> Reachability.put_result(reachability)
    |> bump_filter_version(fresh)
    |> clear_halt(fresh)
  end

  # The kind never changes; enabled changes only through pause and resume,
  # which record their own events; a blank secret keeps the stored one.
  defp update_attrs(attrs) do
    attrs
    |> Map.new()
    |> drop_keys([:kind, :enabled, :start_from])
    |> Map.reject(&blank_secret?/1)
  end

  defp blank_secret?({key, value}), do: to_string(key) in ~w(url credential) and blank?(value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # A save that changes nothing runs no UPDATE, so the optimistic lock never
  # sees a stale lock_version; it is compared here, so a form loaded before
  # another save is refused whether or not it changes anything.
  defp require_current(%Changeset{data: %{lock_version: lock_version}} = changeset, fresh)
       when lock_version != fresh.lock_version,
       do: Changeset.add_error(changeset, :id, "is stale", stale: true)

  defp require_current(changeset, _fresh), do: changeset

  # An unreadable secret can't be kept: it can't be sent with, so the
  # org-admin must enter it again.
  defp require_readable(changeset, fresh) do
    Enum.reduce(@entered_secrets, changeset, fn field, acc ->
      if Map.fetch!(fresh, field) == :unreadable and not Map.has_key?(acc.changes, field),
        do: Changeset.add_error(acc, field, "can't be blank", validation: :unreadable),
        else: acc
    end)
  end

  # The same actions in another order are no change.
  defp drop_reordered_actions(changeset, fresh) do
    with {:ok, actions} <- Changeset.fetch_change(changeset, :excluded_actions),
         true <- Enum.sort(actions) == Enum.sort(fresh.excluded_actions) do
      Changeset.delete_change(changeset, :excluded_actions)
    else
      _changed -> changeset
    end
  end

  defp bump_filter_version(%Changeset{valid?: true} = changeset, fresh) do
    if Enum.any?(@filter_fields, &Map.has_key?(changeset.changes, &1)),
      do: Changeset.put_change(changeset, :filter_version, fresh.filter_version + 1),
      else: changeset
  end

  defp bump_filter_version(changeset, _fresh), do: changeset

  defp clear_halt(%Changeset{valid?: true} = changeset, fresh) do
    if halt_cleared?(fresh.halted_reason, changeset),
      do: Changeset.put_change(changeset, :halted_reason, nil),
      else: changeset
  end

  defp clear_halt(changeset, _fresh), do: changeset

  defp halt_cleared?(:blocked_address, changeset), do: Map.has_key?(changeset.changes, :url)

  # The rejected events may no longer be in the batch: the next run re-cuts
  # it because filter_version changed (D16).
  defp halt_cleared?(:rejected_batch, changeset),
    do: Enum.any?(@filter_fields, &Map.has_key?(changeset.changes, &1))

  defp halt_cleared?(:credentials_unreadable, changeset),
    do: changeset |> Changeset.apply_changes() |> needed_unreadable() == []

  defp halt_cleared?(_reason, _changeset), do: false

  # An unreadable previous signing secret is never needed: rotation drops it.
  defp needed_unreadable(destination),
    do: Destination.unreadable_secrets(destination) -- [:previous_signing_secret]

  # A save that changes no editable field records no event.
  defp save_update(changeset, actor) do
    changed = for field <- @editable_fields, Map.has_key?(changeset.changes, field), do: field

    with {:ok, destination} <- Repo.update(changeset, stale_error_field: :id),
         :ok <- requeue_rejected(changeset) do
      if changed != [],
        do: DestinationEvents.updated(destination, actor, Enum.map(changed, &Atom.to_string/1))

      {:ok, destination}
    end
  end

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

  # Recorded on every call, even one that leaves enabled as it was.
  defp toggle_locked(organization_id, id, enabled, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id),
         {:ok, destination} <- fresh |> Changeset.change(enabled: enabled) |> Repo.update() do
      DestinationEvents.enabled(destination, actor, enabled)
      {:ok, destination}
    end
  end

  # --- delete -------------------------------------------------------------------

  defp delete_locked(organization_id, id, actor) do
    with {:ok, fresh} <- fetch_authorized(actor, organization_id, id) do
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
    |> clear_halt(fresh)
  end

  # --- shared -------------------------------------------------------------------

  defp destination_query(organization_id, id, opts) do
    query = from(d in Destination, where: d.id == ^id and d.organization_id == ^organization_id)
    if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query
  end

  defp one(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      destination -> {:ok, destination}
    end
  end

  defp drop_keys(attrs, keys), do: Map.drop(attrs, keys ++ Enum.map(keys, &Atom.to_string/1))
end
