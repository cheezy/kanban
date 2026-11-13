defmodule Kanban.AuditStream.Gaps do
  @moduledoc """
  The gaps of audit stream destinations: runs of audit events a destination
  will never receive (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6, §9.6,
  §13.1, §13.2).

  `record/4` writes one loss. While a gap of the same destination and reason
  is open (not dismissed), a later loss extends it: its events are added,
  its dates widened and `last_extended_at` moved. A loss with no open gap,
  including one after a dismissal, opens a new gap. `audit_stream_gap` is
  recorded when a gap opens and then at most once a day per gap
  (`audited_at`); `emailed_at` is left for the email reminder, which keeps
  its own 7-day throttle. A loss that extends a gap inside that day is
  recorded by `audit_due/1`, which the minute sweep runs: once the day has
  passed, every open gap that grew since its last event gets one, so no loss
  is left out of the stream for want of a later one. Dismissing a gap that
  grew since its last event records that event first, with the final count. The callers are `Kanban.AuditStream.Retention`
  and `Kanban.AuditStream.AgeLimit`, each holding the destination row lock,
  so two writers never open two gaps.

  `list_gaps/2` and `dismiss_gap/2` are the org-admin's, through
  `Kanban.AuditStream`, and authorize exactly as its other functions do.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.Destinations
  alias Kanban.AuditStream.Gap
  alias Kanban.Repo

  @audit_interval_seconds 24 * 60 * 60

  @typedoc "A destination as `record/4` needs it: the struct, or a map with these keys."
  @type destination :: %{
          required(:id) => pos_integer(),
          required(:organization_id) => pos_integer(),
          required(:kind) => atom(),
          optional(atom()) => term()
        }

  @typedoc "One loss: how many events, and the first and last `inserted_at`."
  @type loss :: %{
          required(:events) => pos_integer(),
          required(:first_at) => DateTime.t(),
          required(:last_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @typedoc "What `emit_recorded/1` reports for one recorded loss."
  @type recorded :: %{kind: atom(), reason: atom(), events: pos_integer()}

  @doc """
  Records `loss` against `destination` for `reason` (`:retention` or
  `:too_old`) at `now`: opens a gap or extends the open one. Call it inside
  the transaction that holds `destination`'s row lock, and pass what it
  returns to `emit_recorded/1` once that transaction commits.
  """
  @spec record(destination(), atom(), loss(), DateTime.t()) ::
          {:ok, recorded()} | {:error, Ecto.Changeset.t()}
  def record(%{id: id} = destination, reason, %{events: events} = loss, %DateTime{} = now)
      when is_integer(events) and events > 0 do
    with {:ok, _gap} <- id |> open_gap(reason) |> write(destination, reason, loss, now) do
      {:ok, %{kind: destination.kind, reason: reason, events: events}}
    end
  end

  @doc "Emits `gap_recorded` for a recorded loss; nothing for `nil`."
  @spec emit_recorded(recorded() | nil) :: :ok
  def emit_recorded(nil), do: :ok

  def emit_recorded(%{kind: kind, reason: reason, events: events}) do
    Kanban.Telemetry.emit(
      [:kanban, :audit_stream, :gap_recorded],
      %{count: 1, events: events},
      %{kind: kind, reason: reason}
    )
  end

  @doc """
  Records `audit_stream_gap` for every open gap that grew since its last one
  and whose last one is at least a day old at `now`, and returns how many it
  recorded. For the minute sweep; each gap is re-checked under its
  destination's row lock, so a sweep and a loss never both record it.
  """
  @spec audit_due(DateTime.t()) :: non_neg_integer()
  def audit_due(%DateTime{} = now) do
    due_before = DateTime.add(now, -@audit_interval_seconds, :second)

    from(g in Gap,
      where:
        is_nil(g.dismissed_at) and g.audited_at <= ^due_before and
          g.last_extended_at > g.audited_at,
      order_by: g.id,
      select: %{id: g.id, destination_id: g.destination_id}
    )
    |> Repo.all()
    |> Enum.count(&(audit_one(&1, now) == {:ok, :recorded}))
  end

  defp audit_one(%{id: id, destination_id: destination_id}, now) do
    Repo.transact(fn ->
      with %{} = destination <- lock_destination(destination_id),
           %Gap{} = gap <- Repo.get_by(Gap, id: id, destination_id: destination_id),
           true <- sweep_due?(gap, now) do
        audit_gap(gap, destination, now)
      else
        _not_due -> {:ok, :skipped}
      end
    end)
  end

  defp sweep_due?(%Gap{dismissed_at: nil} = gap, now),
    do:
      audit_due?(gap.audited_at, now) and
        DateTime.compare(gap.last_extended_at, gap.audited_at) == :gt

  defp sweep_due?(%Gap{}, _now), do: false

  defp audit_gap(gap, destination, now) do
    with {:ok, gap} <- gap |> Gap.changeset(%{audited_at: now}) |> Repo.update() do
      DestinationEvents.gap(destination, gap)
      {:ok, :recorded}
    end
  end

  defp lock_destination(id) do
    from(d in Destination,
      where: d.id == ^id,
      lock: "FOR UPDATE",
      select: %{id: d.id, organization_id: d.organization_id, kind: d.kind}
    )
    |> Repo.one()
  end

  @doc """
  The destination's gaps, open and dismissed, newest first. Org-admins of
  the destination's Organization only.
  """
  @spec list_gaps(Scope.t() | nil, Destination.t()) ::
          {:ok, [Gap.t()]} | {:error, :unauthorized | :not_found}
  def list_gaps(scope, %Destination{id: id}) do
    with {:ok, _actor, organization_id} <- Destinations.authorize(scope),
         {:ok, destination} <- Destinations.fetch(organization_id, id) do
      query =
        from(g in Gap,
          where: g.destination_id == ^destination.id,
          order_by: [desc: g.opened_at, desc: g.id]
        )

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Dismisses `gap` and records `audit_stream_gap_dismissed`, after a last
  `audit_stream_gap` when the gap grew since its previous one. Org-admins of
  the gap's Organization only; the gap is looked up again by id within the
  caller's Organization, never trusted from the struct. Dismissing a gap
  already dismissed returns it as it is and records nothing.
  """
  @spec dismiss_gap(Scope.t() | nil, Gap.t()) ::
          {:ok, Gap.t()} | {:error, :unauthorized | :not_found}
  def dismiss_gap(scope, %Gap{id: gap_id}) do
    with {:ok, actor, organization_id} <- Destinations.authorize(scope) do
      Repo.transact(fn -> dismiss_locked(actor, organization_id, gap_id) end)
    end
  end

  defp dismiss_locked(actor, organization_id, gap_id) do
    with {:ok, destination_id} <- gap_destination(organization_id, gap_id),
         {:ok, destination} <-
           Destinations.fetch_authorized(actor, organization_id, destination_id),
         %{} <- lock_destination(destination.id),
         %Gap{} = gap <- Repo.get_by(Gap, id: gap_id, destination_id: destination.id) do
      dismiss(gap, destination, actor)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp dismiss(%Gap{dismissed_at: nil} = gap, destination, actor) do
    now = DateTime.utc_now()

    with {:ok, gap} <- audit_unaudited(gap, destination, now),
         {:ok, gap} <- gap |> Gap.dismiss_changeset(actor.id, now) |> Repo.update() do
      DestinationEvents.gap_dismissed(destination, actor, gap)
      {:ok, gap}
    end
  end

  defp dismiss(%Gap{} = gap, _destination, _actor), do: {:ok, gap}

  # A gap that grew inside its audit day gets its final audit_stream_gap
  # before the dismissal, since the sweep skips dismissed gaps.
  defp audit_unaudited(gap, destination, now) do
    if DateTime.compare(gap.last_extended_at, gap.audited_at) == :gt do
      with {:ok, gap} <- gap |> Gap.changeset(%{audited_at: now}) |> Repo.update() do
        DestinationEvents.gap(destination, gap)
        {:ok, gap}
      end
    else
      {:ok, gap}
    end
  end

  defp gap_destination(organization_id, gap_id) do
    with {:ok, id} when is_integer(id) <- Ecto.Type.cast(:id, gap_id),
         destination_id when is_integer(destination_id) <-
           organization_id |> gap_destination_query(id) |> Repo.one() do
      {:ok, destination_id}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp gap_destination_query(organization_id, id) do
    from(g in Gap,
      join: d in Destination,
      on: d.id == g.destination_id,
      where: g.id == ^id and d.organization_id == ^organization_id,
      select: g.destination_id
    )
  end

  # --- record -----------------------------------------------------------------

  defp open_gap(destination_id, reason) do
    query =
      from(g in Gap,
        where:
          g.destination_id == ^destination_id and g.reason == ^reason and
            is_nil(g.dismissed_at),
        order_by: [desc: g.opened_at, desc: g.id],
        limit: 1
      )

    Repo.one(query)
  end

  defp write(nil, destination, reason, loss, now) do
    attrs = %{
      destination_id: destination.id,
      reason: reason,
      events: loss.events,
      first_occurred_at: loss.first_at,
      last_occurred_at: loss.last_at,
      opened_at: now,
      last_extended_at: now,
      audited_at: now
    }

    with {:ok, gap} <- %Gap{} |> Gap.changeset(attrs) |> Repo.insert() do
      DestinationEvents.gap(destination, gap)
      {:ok, gap}
    end
  end

  defp write(%Gap{} = gap, destination, _reason, loss, now) do
    audit? = audit_due?(gap.audited_at, now)

    attrs =
      %{
        events: gap.events + loss.events,
        first_occurred_at: earliest(gap.first_occurred_at, loss.first_at),
        last_occurred_at: latest(gap.last_occurred_at, loss.last_at),
        last_extended_at: now
      }
      |> put_audited(audit?, now)

    with {:ok, gap} <- gap |> Gap.changeset(attrs) |> Repo.update() do
      if audit?, do: DestinationEvents.gap(destination, gap)
      {:ok, gap}
    end
  end

  defp audit_due?(nil, _now), do: true
  defp audit_due?(audited_at, now), do: DateTime.diff(now, audited_at) >= @audit_interval_seconds

  defp put_audited(attrs, true, now), do: Map.put(attrs, :audited_at, now)
  defp put_audited(attrs, false, _now), do: attrs

  defp earliest(a, b), do: Enum.min([a, b], DateTime)
  defp latest(a, b), do: Enum.max([a, b], DateTime)
end
