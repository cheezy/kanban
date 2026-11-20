defmodule Kanban.Notifications.PushSettingsStore do
  @moduledoc """
  Reads and writes a person's push settings
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9): the
  `user_push_settings` row and the eight `push` switches on
  `notification_preferences`. `Kanban.Notifications` delegates here; the data
  and validation rules are in `Kanban.Notifications.PushSettings`.

  Every function acts on the scope's user only.

    * `get/1` returns the settings, falling back to the defaults for a person
      with no row and for event types with no saved preference. It writes
      nothing.
    * `update/3` creates the row on the first change, then applies the change
      under a row lock, so two changes at once are applied one after the
      other and neither loses a field. Each write touches only the columns it
      changes: a switch write replaces only `push`, so it never undoes a
      concurrent in-app or email change, and a settings write sets only the
      columns that changed. A mode applies its preset only when it differs
      from the stored mode, and switches sent in the same request then win.
      Once the change commits, and only when something changed, it emits
      `[:kanban, :push, :settings_changed]` with the mode, the names of the
      changed fields and `via`; never a value such as the time zone.
    * `ensure_for_device/1` creates the row when a person's first device
      registers, with that device's time zone. A later device never moves a
      zone that is already set; it only fills one that is still empty.

  ## Quiet-hours summaries

  `last_summary_at` records when `Kanban.Push.SummaryWorker` last took a
  quiet period's summary. `summary_candidates/1` lists the rows the worker
  looks at, and the worker takes a period with `claim_summary/3` or
  `claim_ended_summary/3`, conditional updates that only one run can win, so
  overlapping runs send one summary. `release_summary/3` gives a period back
  when no device got its summary because of a passing failure.

  A change to quiet hours (on or off, the times or the zone) also decides
  what the next summary covers:

    * made outside quiet hours while a one-person summary job is queued,
      retrying or running, it leaves the summary to that job: no second job
      and no stamp, so the job still sends it once;
    * made outside quiet hours while a period's summary is due, it enqueues
      the summary at once, so the change never cancels it;
    * made outside quiet hours otherwise, it sets `last_summary_at` to now,
      so a period that ended before quiet hours were on, or one the new
      settings would have had, gets no summary;
    * made inside quiet hours that it ends, such as turning them off or
      moving to a zone where they are over, it enqueues the summary for the
      period it ended (`Kanban.Push.SummaryWorker.enqueue_ended/2`), in the
      same transaction;
    * made inside quiet hours that still hold, it changes nothing: the
      summary follows when the new period ends.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
  alias Kanban.Plans
  alias Kanban.Push.QuietHours
  alias Kanban.Push.SummaryWorker
  alias Kanban.Repo

  @settings_fields [:mode, :quiet_hours_enabled, :quiet_start, :quiet_end, :time_zone]
  @quiet_fields [:quiet_hours_enabled, :quiet_start, :quiet_end, :time_zone]

  @doc """
  Returns the scoped user's push settings view. Writes nothing.
  """
  @spec get(Scope.t()) :: PushSettings.view()
  def get(%Scope{user: %User{id: user_id}}) do
    settings = Repo.get(PushSettings, user_id) || PushSettings.defaults(user_id)
    view(settings, switches(user_id))
  end

  @doc """
  Applies a settings change for the scoped user and returns the new view.

  `attrs` is validated by `PushSettings.request_changeset/2`. Options:

    * `:via` (required): who made the change, `:ios` or `:android` from the
      app; `:web` from the web preferences page, `/users/notifications`;
    * `:feature` (required): the plan feature the calling surface is gated
      by, checked with `Kanban.Plans.check_user/3`, so a crafted call cannot
      change a locked setting;
    * `:device` (optional): the device making the change. It is locked
      `FOR SHARE` before anything is written, so a device revoked, or a user
      disabled, while the request was in flight changes nothing and gets
      `{:error, :revoked}`, and a revocation that starts later waits for the
      change to commit.
  """
  @spec update(Scope.t(), map(), keyword()) ::
          {:ok, PushSettings.view()}
          | {:error, Ecto.Changeset.t() | {:plan_required, atom()} | :revoked}
  def update(%Scope{user: %User{id: user_id}} = scope, attrs, opts) when is_map(attrs) do
    via = Keyword.fetch!(opts, :via)
    feature = Keyword.fetch!(opts, :feature)
    device = Keyword.get(opts, :device)

    with :ok <- Plans.check_user(scope, feature, surface: :context),
         {:ok, {view, changed}} <- transact_change(device, user_id, attrs) do
      emit_changed(view, changed, via)
      {:ok, view}
    end
  end

  @doc """
  Creates the push settings row for a device's user, with the device's time
  zone, when it does not exist yet; fills the zone of a row that has none.
  Takes and returns the result of inserting the device, so it can be piped
  after `Repo.insert/1`. Raises if the row cannot be written, which rolls back
  an enclosing transaction.
  """
  @spec ensure_for_device({:ok, Device.t()} | {:error, term()}) ::
          {:ok, Device.t()} | {:error, term()}
  def ensure_for_device({:ok, %Device{user_id: user_id, time_zone: zone} = device}) do
    now = now()

    fill_empty_zone =
      from(s in PushSettings,
        where: is_nil(s.time_zone),
        update: [set: [time_zone: ^zone, updated_at: ^now]]
      )

    Repo.insert_all(
      PushSettings,
      [%{user_id: user_id, time_zone: zone, inserted_at: now, updated_at: now}],
      on_conflict: fill_empty_zone,
      conflict_target: :user_id
    )

    {:ok, device}
  end

  def ensure_for_device({:error, _reason} = error), do: error

  @doc """
  The settings rows the summary worker looks at, at `now`: quiet hours on,
  a time zone set, no summary taken at or after `now`, and an enabled,
  confirmed user.
  """
  @spec summary_candidates(DateTime.t()) :: [PushSettings.t()]
  def summary_candidates(%DateTime{} = now) do
    from(s in PushSettings,
      join: u in User,
      on: u.id == s.user_id,
      where: s.quiet_hours_enabled and not is_nil(s.time_zone),
      where: is_nil(u.disabled_at) and not is_nil(u.confirmed_at),
      where: is_nil(s.last_summary_at) or s.last_summary_at < ^now,
      order_by: s.user_id
    )
    |> Repo.all()
  end

  @doc """
  Takes the summary of the quiet period that ended at `period_end` for the
  person `settings` belong to, by setting `last_summary_at` to `now`.

  It succeeds only when the stored quiet hours are still the ones in
  `settings` and no summary was taken at or after `period_end`, so of two
  runs at once only one gets `:claimed`; the other gets `:taken`.
  """
  @spec claim_summary(PushSettings.t(), DateTime.t(), DateTime.t()) :: :claimed | :taken
  def claim_summary(%PushSettings{} = settings, %DateTime{} = period_end, %DateTime{} = now) do
    PushSettings
    |> where([s], s.user_id == ^settings.user_id and s.quiet_hours_enabled)
    |> where([s], s.time_zone == ^settings.time_zone)
    |> where([s], s.quiet_start == ^settings.quiet_start and s.quiet_end == ^settings.quiet_end)
    |> summary_not_taken(period_end)
    |> claim(now)
  end

  @doc """
  Takes the summary of a quiet period a settings change ended at `ended_at`,
  as `claim_summary/3` does, whatever the quiet hours are now.
  """
  @spec claim_ended_summary(pos_integer(), DateTime.t(), DateTime.t()) :: :claimed | :taken
  def claim_ended_summary(user_id, %DateTime{} = ended_at, %DateTime{} = now) do
    PushSettings
    |> where([s], s.user_id == ^user_id)
    |> summary_not_taken(ended_at)
    |> claim(now)
  end

  @doc """
  Gives back a summary taken at `now`, restoring `previous`, so the next run
  can send it. A summary taken again since is left alone.
  """
  @spec release_summary(pos_integer(), DateTime.t() | nil, DateTime.t()) :: :ok
  def release_summary(user_id, previous, %DateTime{} = now) do
    PushSettings
    |> where([s], s.user_id == ^user_id and s.last_summary_at == ^now)
    |> Repo.update_all(set: [last_summary_at: previous])

    :ok
  end

  defp summary_not_taken(query, period_end),
    do: where(query, [s], is_nil(s.last_summary_at) or s.last_summary_at < ^period_end)

  defp claim(query, now) do
    case Repo.update_all(query, set: [last_summary_at: DateTime.truncate(now, :second)]) do
      {1, _} -> :claimed
      {0, _} -> :taken
    end
  end

  defp transact_change(device, user_id, attrs) do
    Repo.transact(fn ->
      with :ok <- lock_active_device(device), do: apply_change(user_id, attrs)
    end)
  end

  defp lock_active_device(nil), do: :ok

  defp lock_active_device(%Device{id: device_id}) do
    query =
      from(d in Device,
        join: u in User,
        on: u.id == d.user_id,
        where: d.id == ^device_id and is_nil(d.revoked_at) and is_nil(u.disabled_at),
        lock: "FOR SHARE",
        select: d.id
      )

    if Repo.one(query), do: :ok, else: {:error, :revoked}
  end

  defp apply_change(user_id, attrs) do
    settings = lock_row(user_id)
    switches = switches(user_id)
    current = view(settings, switches)
    changeset = PushSettings.request_changeset(current, attrs)

    if changeset.valid? do
      {:ok, write_changes(settings, current, changeset.changes)}
    else
      {:error, changeset}
    end
  end

  # Writes only what differs from `current`; returns the new view and the
  # sorted names of the changed fields.
  defp write_changes(%PushSettings{user_id: user_id} = settings, current, changes) do
    now = now()
    settings_changes = changed_settings(current, changes)
    switch_changes = changed_switches(current, changes)

    new_view = merge_view(current, settings_changes, switch_changes)
    quiet = quiet_change(settings, current, new_view, settings_changes, now)

    :ok = write_settings(user_id, settings_changes, quiet, now)
    :ok = write_switches(user_id, switch_changes)
    :ok = summarize_ended(user_id, quiet, now)

    {new_view, changed_names(settings_changes, switch_changes)}
  end

  defp merge_view(current, settings_changes, switch_changes) do
    %{
      Map.merge(current, settings_changes)
      | switches: Map.merge(current.switches, switch_changes)
    }
  end

  defp changed_names(settings_changes, switch_changes) do
    (Map.keys(settings_changes) ++ Map.keys(switch_changes))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  # What a quiet-hours change means for the next summary (see the moduledoc).
  # A one-person summary job that is queued, retrying or running already
  # covers the summary owed, so the change leaves it alone: a second job
  # would claim again after the first one's claim and send a second summary,
  # and a stamp would make a job that has not claimed yet find it taken.
  defp quiet_change(settings, current, new_view, settings_changes, now) do
    cond do
      not Enum.any?(@quiet_fields, &Map.has_key?(settings_changes, &1)) -> :none
      QuietHours.inside?(current, now) and QuietHours.inside?(new_view, now) -> :none
      QuietHours.inside?(current, now) -> :ended
      SummaryWorker.pending?(settings.user_id) -> :none
      SummaryWorker.due(settings, now) != :not_due -> :ended
      true -> :stamp
    end
  end

  defp summarize_ended(user_id, :ended, now) do
    {:ok, _job} = SummaryWorker.enqueue_ended(user_id, now)
    :ok
  end

  defp summarize_ended(_user_id, _quiet, _now), do: :ok

  # Creates the row with its defaults if it is missing, then locks it, so
  # concurrent changes for one person run one after the other.
  defp lock_row(user_id) do
    now = now()

    Repo.insert_all(
      PushSettings,
      [%{user_id: user_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: :user_id
    )

    PushSettings
    |> where([s], s.user_id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp changed_settings(current, changes) do
    changes
    |> Map.take(@settings_fields)
    |> Map.reject(fn {field, value} -> Map.fetch!(current, field) == value end)
  end

  # A mode sets its preset only when it is a different mode: the changeset
  # records `:mode` only when it differs from the stored one. Switches sent
  # with it then override the preset. Only switches whose value changes are
  # kept.
  defp changed_switches(current, changes) do
    preset =
      case Map.fetch(changes, :mode) do
        {:ok, mode} -> PushSettings.preset(mode)
        :error -> %{}
      end

    preset
    |> Map.merge(Map.take(changes, PushSettings.push_events()))
    |> Map.reject(fn {type, value} -> Map.fetch!(current.switches, type) == value end)
  end

  defp write_settings(_user_id, changes, _quiet, _now) when map_size(changes) == 0, do: :ok

  defp write_settings(user_id, changes, quiet, now) do
    set = Keyword.new(changes) ++ [updated_at: now] ++ summary_stamp(quiet, now)

    {1, _} =
      PushSettings
      |> where([s], s.user_id == ^user_id)
      |> Repo.update_all(set: set)

    :ok
  end

  defp summary_stamp(:stamp, now), do: [last_summary_at: now]
  defp summary_stamp(_quiet, _now), do: []

  defp write_switches(_user_id, changes) when map_size(changes) == 0, do: :ok

  # A new preference row takes the in-app and email values the person has
  # now (the defaults, since there is no row); an existing row has only its
  # push switch replaced, so a concurrent in-app or email change survives.
  defp write_switches(user_id, changes) do
    now = DateTime.utc_now()
    saved = saved_preferences(user_id, Map.keys(changes))

    rows =
      for {type, push} <- changes do
        current = Map.get_lazy(saved, type, fn -> Notifications.default_preference(type) end)

        %{
          user_id: user_id,
          event_type: type,
          in_app: current.in_app,
          email: current.email,
          push: push,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Preference, rows,
      on_conflict: {:replace, [:push, :updated_at]},
      conflict_target: [:user_id, :event_type]
    )

    :ok
  end

  defp saved_preferences(user_id, types) do
    Preference
    |> where([p], p.user_id == ^user_id and p.event_type in ^types)
    |> Repo.all()
    |> Map.new(&{&1.event_type, &1})
  end

  defp switches(user_id) do
    saved =
      Preference
      |> where([p], p.user_id == ^user_id and p.event_type in ^PushSettings.push_events())
      |> select([p], {p.event_type, p.push})
      |> Repo.all()
      |> Map.new()

    Map.new(PushSettings.push_events(), fn type ->
      {type, Map.get_lazy(saved, type, fn -> PushSettings.default_push?(type) end)}
    end)
  end

  defp view(%PushSettings{} = settings, switches) do
    settings
    |> Map.take(@settings_fields)
    |> Map.put(:switches, switches)
  end

  defp emit_changed(_view, [], _via), do: :ok

  defp emit_changed(view, changed, via) do
    Kanban.Telemetry.emit([:kanban, :push, :settings_changed], %{count: 1}, %{
      mode: view.mode,
      fields: changed,
      via: via
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
