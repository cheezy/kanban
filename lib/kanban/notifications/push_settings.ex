defmodule Kanban.Notifications.PushSettings do
  @moduledoc """
  A person's push settings (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.9, §8): one `user_push_settings` row holding the mode, quiet hours and
  the one time zone quiet hours follow, plus the event groups and the mode
  presets. This module holds data and validation only; every query lives in
  `Kanban.Notifications.PushSettingsStore`.

  ## The eight push events

  Push is a per-event switch, `Kanban.Notifications.Preference`'s `push`
  column. Eight event types can push, in two groups:

    * decisions: `review_requested`, `task_unclaimed`, `claim_expired` and
      `after_goal_failed`, on by default;
    * updates: `task_reviewed`, `goal_completed`, `target_status_changed` and
      `mentioned`, off by default.

  The other four types (`never_push_events/0`) never push, and a request to
  turn one on is refused.

  ## Modes are presets

  `mode` is `:decisions` (the default) or `:every`. Choosing a mode sets the
  eight switches to `preset/1`; each switch can then be changed on its own.
  The push worker reads only the switches, never the mode.

  ## Time zone

  `time_zone` is the only zone quiet hours use. It is taken from the first
  device that registers, or set by a settings change; a later device never
  moves it. It is `nil` until one of those gives it a value.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Notifications.Preference

  @decision_events [:review_requested, :task_unclaimed, :claim_expired, :after_goal_failed]
  @update_events [:task_reviewed, :goal_completed, :target_status_changed, :mentioned]
  @push_events @decision_events ++ @update_events
  @never_push_events Preference.event_types() -- @push_events
  @modes [:decisions, :every]

  @default_quiet_start ~T[22:00:00]
  @default_quiet_end ~T[07:00:00]

  # The settings a request may change, besides the switches.
  @settings_fields [:mode, :quiet_hours_enabled, :quiet_start, :quiet_end, :time_zone]
  @varchar_max 255
  @time_format ~r/\A([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?\z/

  @type mode :: :decisions | :every
  @type t :: %__MODULE__{}

  @typedoc """
  A person's settings as the API shows them: the row (or its defaults) and
  the eight switches.
  """
  @type view :: %{
          mode: mode(),
          switches: %{atom() => boolean()},
          quiet_hours_enabled: boolean(),
          quiet_start: Time.t(),
          quiet_end: Time.t(),
          time_zone: String.t() | nil
        }

  @primary_key {:user_id, :id, autogenerate: false}
  schema "user_push_settings" do
    field :mode, Ecto.Enum, values: @modes, default: :decisions
    field :quiet_hours_enabled, :boolean, default: false
    field :quiet_start, :time, default: @default_quiet_start
    field :quiet_end, :time, default: @default_quiet_end
    field :time_zone, :string
    field :last_summary_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "The four decision events, on by default."
  @spec decision_events() :: [atom()]
  def decision_events, do: @decision_events

  @doc "The four update events, off by default."
  @spec update_events() :: [atom()]
  def update_events, do: @update_events

  @doc "The eight event types that can push: decisions first, then updates."
  @spec push_events() :: [atom()]
  def push_events, do: @push_events

  @doc "The event types that never push."
  @spec never_push_events() :: [atom()]
  def never_push_events, do: @never_push_events

  @doc "The modes, in display order."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  The default push switch for an event type: on for the four decision
  events, off for everything else.
  """
  @spec default_push?(atom()) :: boolean()
  def default_push?(event_type), do: event_type in @decision_events

  @doc """
  The eight switches a mode sets: `:decisions` turns the decision events on
  and the updates off; `:every` turns all eight on.
  """
  @spec preset(mode()) :: %{atom() => boolean()}
  def preset(:decisions), do: Map.new(@push_events, &{&1, &1 in @decision_events})
  def preset(:every), do: Map.new(@push_events, &{&1, true})

  @doc """
  The unsaved settings a person without a row has.
  """
  @spec defaults(pos_integer()) :: t()
  def defaults(user_id) when is_integer(user_id), do: %__MODULE__{user_id: user_id}

  @doc """
  Validates a settings change against `current`, the person's current view.

  `attrs` has string keys: any of `"mode"`, `"quiet_hours_enabled"`,
  `"quiet_start"`, `"quiet_end"`, `"time_zone"` and `"switches"`, a map from
  event type name to boolean. Other keys, and switches for unknown event
  types, are ignored. Times are `"HH:MM"` or `"HH:MM:SS"` and are kept to the
  minute.

  Refuses quiet hours that start when they end, a time zone the tz database
  does not know exactly as sent, and `true` for an event that never pushes
  (`false` for one is accepted and changes nothing). Quiet hours may span
  midnight.

  Returns a schemaless changeset whose changes are the requested values; the
  switch changes are keyed by event type atom.
  """
  @spec request_changeset(view(), map()) :: Ecto.Changeset.t()
  def request_changeset(current, attrs) when is_map(attrs) do
    {switches, switches_error} = take_switches(Map.get(attrs, "switches"))

    {request_data(current), types()}
    |> cast(request_params(attrs, switches), Map.keys(types()))
    |> validate_required([:mode, :quiet_hours_enabled, :quiet_start, :quiet_end])
    |> validate_settings(attrs)
    |> validate_switches(switches, switches_error)
  end

  defp validate_settings(changeset, attrs) do
    changeset
    |> validate_time_format(attrs, [:quiet_start, :quiet_end])
    |> truncate_minutes([:quiet_start, :quiet_end])
    |> validate_quiet_range()
    |> validate_time_zone(attrs)
    |> validate_quiet_hours_zone()
  end

  defp validate_switches(changeset, switches, switches_error) do
    changeset
    |> validate_switch_values(switches)
    |> validate_never_push()
    |> add_switches_error(switches_error)
  end

  defp types do
    settings = %{
      mode: Ecto.ParameterizedType.init(Ecto.Enum, values: @modes),
      quiet_hours_enabled: :boolean,
      quiet_start: :time,
      quiet_end: :time,
      time_zone: :string
    }

    Map.merge(settings, Map.new(event_names(), &{&1, :boolean}))
  end

  # The current settings, and no value for each switch, so that every switch
  # sent is a change, a false one included.
  defp request_data(current) do
    current
    |> Map.take(@settings_fields)
    |> Map.merge(Map.new(event_names(), &{&1, nil}))
  end

  defp request_params(attrs, switches) do
    attrs
    |> Map.take(settings_keys())
    |> Map.merge(switches)
  end

  defp event_names, do: Preference.event_types()

  defp settings_keys, do: Enum.map(@settings_fields, &Atom.to_string/1)

  defp take_switches(nil), do: {%{}, nil}

  defp take_switches(switches) when is_map(switches),
    do: {Map.take(switches, Enum.map(event_names(), &Atom.to_string/1)), nil}

  defp take_switches(_other), do: {%{}, "is invalid"}

  defp add_switches_error(changeset, nil), do: changeset
  defp add_switches_error(changeset, message), do: add_error(changeset, :switches, message)

  # Ecto's :time cast also takes offsets ("22:00+05:00", dropping the
  # offset), signed hours ("+7:05") and maps, so the text sent is checked
  # first. A nil is left to validate_required.
  defp validate_time_format(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case Map.fetch(attrs, Atom.to_string(field)) do
        {:ok, nil} -> acc
        {:ok, value} when is_binary(value) -> check_time_format(acc, field, value)
        {:ok, _other} -> add_invalid_error(acc, field)
        :error -> acc
      end
    end)
  end

  defp check_time_format(changeset, field, value) do
    if value =~ @time_format, do: changeset, else: add_invalid_error(changeset, field)
  end

  # One "is invalid" per field, whether or not the cast already refused it.
  defp add_invalid_error(changeset, field) do
    if Keyword.has_key?(changeset.errors, field),
      do: changeset,
      else: add_error(changeset, field, "is invalid")
  end

  # A switch sent as null or "" casts to no change; it is refused like any
  # other value that is not a boolean.
  defp validate_switch_values(changeset, switches) do
    Enum.reduce(switches, changeset, fn {name, _value}, acc ->
      type = String.to_existing_atom(name)

      case fetch_change(acc, type) do
        {:ok, value} when is_boolean(value) -> acc
        _no_boolean -> add_invalid_error(acc, type)
      end
    end)
  end

  defp truncate_minutes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, %Time{} = time} -> put_change(acc, field, %{time | second: 0, microsecond: {0, 0}})
        _no_change -> acc
      end
    end)
  end

  defp validate_quiet_range(changeset) do
    start = get_field(changeset, :quiet_start)

    if start != nil and start == get_field(changeset, :quiet_end) do
      add_error(changeset, :quiet_end, "can't be the same as the start")
    else
      changeset
    end
  end

  # A zone is stored only when the tz database knows it exactly as sent, as
  # Kanban.Devices.Device does: a padded, case-variant or invented zone would
  # be read back as UTC. A zone sent as null, "" or blanks is refused whether
  # or not one is stored, so a stored zone cannot be cleared.
  defp validate_time_zone(changeset, attrs) do
    if blank_zone?(Map.fetch(attrs, "time_zone")),
      do: add_error(changeset, :time_zone, "is not a known time zone"),
      else: validate_zone_change(changeset)
  end

  defp blank_zone?({:ok, nil}), do: true
  defp blank_zone?({:ok, zone}) when is_binary(zone), do: String.trim(zone) == ""
  defp blank_zone?(_not_sent_or_not_text), do: false

  defp validate_zone_change(changeset) do
    case fetch_change(changeset, :time_zone) do
      {:ok, zone} ->
        changeset
        |> validate_length(:time_zone, max: @varchar_max, count: :codepoints)
        |> check_zone(zone)

      :error ->
        changeset
    end
  end

  # Quiet hours follow the person's time zone, so they cannot be turned on
  # while there is none, stored or sent.
  defp validate_quiet_hours_zone(changeset) do
    if fetch_change(changeset, :quiet_hours_enabled) == {:ok, true} and
         get_field(changeset, :time_zone) == nil and
         not Keyword.has_key?(changeset.errors, :time_zone) do
      add_error(changeset, :quiet_hours_enabled, "needs a time zone")
    else
      changeset
    end
  end

  defp check_zone(changeset, zone) do
    case DateTime.now(zone) do
      {:ok, _now} -> changeset
      {:error, _reason} -> add_error(changeset, :time_zone, "is not a known time zone")
    end
  end

  defp validate_never_push(changeset) do
    Enum.reduce(@never_push_events, changeset, fn type, acc ->
      case fetch_change(acc, type) do
        {:ok, true} -> add_error(acc, type, "never pushes")
        _false_or_absent -> acc
      end
    end)
  end
end
