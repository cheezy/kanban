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
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
  alias Kanban.Plans
  alias Kanban.Repo

  @settings_fields [:mode, :quiet_hours_enabled, :quiet_start, :quiet_end, :time_zone]

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
      app; `:web` is reserved for the web preferences page;
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
      {:ok, write_changes(user_id, current, changeset.changes)}
    else
      {:error, changeset}
    end
  end

  # Writes only what differs from `current`; returns the new view and the
  # sorted names of the changed fields.
  defp write_changes(user_id, current, changes) do
    settings_changes = changed_settings(current, changes)
    switch_changes = changed_switches(current, changes)

    :ok = write_settings(user_id, settings_changes)
    :ok = write_switches(user_id, switch_changes)

    changed =
      (Map.keys(settings_changes) ++ Map.keys(switch_changes))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    new_view = %{
      Map.merge(current, settings_changes)
      | switches: Map.merge(current.switches, switch_changes)
    }

    {new_view, changed}
  end

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

  defp write_settings(_user_id, changes) when map_size(changes) == 0, do: :ok

  defp write_settings(user_id, changes) do
    set = Keyword.new(changes) ++ [updated_at: now()]

    {1, _} =
      PushSettings
      |> where([s], s.user_id == ^user_id)
      |> Repo.update_all(set: set)

    :ok
  end

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
