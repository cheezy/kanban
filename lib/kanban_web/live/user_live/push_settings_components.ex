defmodule KanbanWeb.UserLive.PushSettingsComponents do
  @moduledoc """
  The push parts of `/users/notifications`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9): the per-row Push
  switch, the mode preset card and the quiet hours card, plus the helpers
  that turn a `Kanban.Notifications.PushSettings.view/0` into form values and
  a refused settings change into translated field errors.

  The components only render. `KanbanWeb.UserLive.NotificationPreferences`
  owns the events and saves every change through
  `Kanban.Notifications.update_push_settings/3`.
  """
  use KanbanWeb, :html

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  alias Kanban.Notifications.PushSettings

  # Zones offered by the quiet hours picker. The person's stored zone and the
  # browser's zone are added to this list when they are not already on it,
  # so nobody is shown a zone other than their own.
  @zones ~w(
    Etc/UTC
    Europe/London Europe/Dublin Europe/Lisbon Europe/Paris Europe/Berlin
    Europe/Madrid Europe/Rome Europe/Amsterdam Europe/Brussels Europe/Zurich
    Europe/Stockholm Europe/Oslo Europe/Copenhagen Europe/Helsinki
    Europe/Warsaw Europe/Prague Europe/Vienna Europe/Athens Europe/Istanbul
    Europe/Kyiv Europe/Moscow
    Africa/Casablanca Africa/Lagos Africa/Cairo Africa/Nairobi
    Africa/Johannesburg
    Asia/Dubai Asia/Karachi Asia/Kolkata Asia/Dhaka Asia/Bangkok
    Asia/Jakarta Asia/Singapore Asia/Shanghai Asia/Hong_Kong Asia/Taipei
    Asia/Manila Asia/Seoul Asia/Tokyo
    Australia/Perth Australia/Adelaide Australia/Brisbane Australia/Sydney
    Pacific/Auckland Pacific/Honolulu
    America/Anchorage America/Los_Angeles America/Vancouver America/Denver
    America/Phoenix America/Chicago America/Mexico_City America/New_York
    America/Toronto America/Halifax America/Bogota America/Lima
    America/Santiago America/Sao_Paulo America/Argentina/Buenos_Aires
    America/St_Johns
  )

  @doc "The zones the quiet hours picker always offers."
  @spec zones() :: [String.t()]
  def zones, do: @zones

  @doc """
  The picker's `{label, value}` options: `zones/0` plus `stored` and
  `browser` when they are zones not already listed, sorted by name. A `nil`
  or unknown zone adds nothing.
  """
  @spec zone_options(String.t() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def zone_options(stored, browser) do
    [stored, browser]
    |> Enum.filter(&known_zone?/1)
    |> Enum.concat(@zones)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{String.replace(&1, "_", " "), &1})
  end

  defp known_zone?(zone), do: match?({:ok, _zone}, KanbanWeb.Timezone.parse_timezone(zone))

  @doc """
  The quiet hours form values for a push settings view, with string keys.

  The zone is the stored one; with none stored it is `browser`, the zone the
  page was opened in, unless that is the `"Etc/UTC"` fallback, so the picker
  suggests the person's own zone rather than defaulting to UTC.
  """
  @spec quiet_params(PushSettings.view(), String.t() | nil) :: %{String.t() => term()}
  def quiet_params(view, browser) do
    %{
      "quiet_hours_enabled" => view.quiet_hours_enabled,
      "quiet_start" => minutes(view.quiet_start),
      "quiet_end" => minutes(view.quiet_end),
      "time_zone" => view.time_zone || suggested_zone(browser)
    }
  end

  defp minutes(%Time{} = time), do: time |> Time.to_iso8601() |> binary_part(0, 5)

  defp suggested_zone("Etc/UTC"), do: ""

  defp suggested_zone(zone) do
    if known_zone?(zone), do: zone, else: ""
  end

  @doc """
  Translated messages for the quiet hours fields a refused settings change
  names, keyed by field. The context's messages are English, so each one is
  mapped to a message of this page's own.
  """
  @spec quiet_errors(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def quiet_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.flat_map(&quiet_error/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(&unique_messages/1)
  end

  defp quiet_error({field, {message, _opts}}), do: quiet_error(field, message)

  defp unique_messages({field, messages}), do: {field, Enum.uniq(messages)}

  defp quiet_error(:quiet_end, "can't be the same as the start"),
    do: [{:quiet_end, gettext("Quiet hours can't start and end at the same time.")}]

  defp quiet_error(field, _message) when field in [:quiet_start, :quiet_end],
    do: [{field, gettext("Enter a time, such as 22:00.")}]

  defp quiet_error(:time_zone, _message),
    do: [{:time_zone, gettext("Choose a time zone from the list.")}]

  defp quiet_error(:quiet_hours_enabled, _message),
    do: [{:quiet_hours_enabled, gettext("Choose a time zone to turn on quiet hours.")}]

  defp quiet_error(_field, _message), do: []

  @doc """
  The Push switch for one event row, or an invisible spacer of the same
  width for an event that never pushes, so the columns stay aligned.
  """
  attr :type, :atom, required: true
  attr :switches, :map, required: true
  attr :toggle_layout, :string, required: true

  def push_switch(assigns) do
    assigns = assign(assigns, :pushable, assigns.type in PushSettings.push_events())

    ~H"""
    <form
      :if={@pushable}
      id={"push-#{@type}"}
      phx-change="save_push"
      class={["flex", @toggle_layout]}
      style="margin: 0;"
    >
      <input type="hidden" name="event_type" value={@type} />
      <.input
        type="checkbox"
        id={"pref-#{@type}-push"}
        name="push"
        aria-describedby={"pref-#{@type}-name"}
        value={Map.get(@switches, @type, false)}
        label={gettext("Push")}
      />
    </form>
    <span
      :if={!@pushable}
      data-push-none
      aria-hidden="true"
      class="invisible hidden @md:inline-flex items-center gap-2"
      style="font-size: 14px;"
    >
      <span style="display: inline-block; width: 20px; height: 20px;"></span>
      {gettext("Push")}
    </span>
    """
  end

  @doc """
  The value the mode select shows for a push settings view: the stored mode
  while the eight switches still match its preset, else the mode whose preset
  they match, else `"custom"`, so a switch changed on its own is never shown
  under a preset it no longer follows.
  """
  @spec mode_value(PushSettings.view()) :: String.t()
  def mode_value(%{mode: mode, switches: switches}) when is_map(switches) do
    current = Map.take(switches, PushSettings.push_events())

    case Enum.find([mode | PushSettings.modes()], &(PushSettings.preset(&1) == current)) do
      nil -> "custom"
      matched -> Atom.to_string(matched)
    end
  end

  @doc """
  The mode select's options: the presets, plus a disabled "Custom" entry
  while `value` is `"custom"`, so it can be shown selected but never chosen.
  """
  @spec mode_options(String.t()) :: [{String.t(), String.t()} | keyword()]
  def mode_options(value) do
    presets = [
      {gettext("Decisions only (Recommended)"), "decisions"},
      {gettext("Every event"), "every"}
    ]

    if value == "custom",
      do: presets ++ [[key: gettext("Custom"), value: "custom", disabled: true]],
      else: presets
  end

  @doc "The mode preset card: one select that sets the eight Push switches."
  attr :push, :map, required: true

  def push_mode_card(assigns) do
    assigns = assign(assigns, :mode_value, mode_value(assigns.push))

    ~H"""
    <.settings_card
      id="push-mode"
      title={gettext("Push notifications")}
      hint={
        gettext(
          "Pushes go to the Stride app on your phone. Pick a preset, then change any event below."
        )
      }
      level={3}
      compact
    >
      <form
        id="push-mode-form"
        phx-change="save_push_mode"
        class="[&_.label]:whitespace-normal"
        style="margin: 0; padding: 10px 0; max-width: 320px;"
      >
        <.input
          type="select"
          id="push-mode-select"
          name="mode"
          label={gettext("Notify me")}
          value={@mode_value}
          options={mode_options(@mode_value)}
        />
      </form>
    </.settings_card>
    """
  end

  @doc """
  The quiet hours card: on or off, start, end and the time zone they follow.
  It saves on submit, because turning quiet hours on needs a zone and a time
  field changes on every keystroke.
  """
  attr :params, :map, required: true
  attr :errors, :map, required: true
  attr :zone_options, :list, required: true
  attr :toggle_layout, :string, required: true

  def quiet_hours_card(assigns) do
    ~H"""
    <.settings_card
      id="push-quiet-hours"
      title={gettext("Quiet hours")}
      hint={
        gettext(
          "Pushes wait during quiet hours and arrive as one summary when they end. Quiet hours follow the time zone you choose here."
        )
      }
      level={3}
      compact
    >
      <form
        id="push-quiet-hours-form"
        phx-submit="save_quiet_hours"
        class="flex flex-col gap-3 min-w-0"
        style="margin: 0; padding: 10px 0;"
      >
        <div class={@toggle_layout}>
          <.input
            type="checkbox"
            id="push-quiet_hours_enabled"
            name="quiet_hours_enabled"
            value={@params["quiet_hours_enabled"]}
            label={gettext("Turn on quiet hours")}
            errors={Map.get(@errors, :quiet_hours_enabled, [])}
          />
        </div>
        <div class="grid grid-cols-1 @md:grid-cols-3 gap-3 min-w-0 [&_.label]:whitespace-normal">
          <.input
            type="time"
            id="push-quiet_start"
            name="quiet_start"
            value={@params["quiet_start"]}
            label={gettext("Starts")}
            errors={Map.get(@errors, :quiet_start, [])}
          />
          <.input
            type="time"
            id="push-quiet_end"
            name="quiet_end"
            value={@params["quiet_end"]}
            label={gettext("Ends")}
            errors={Map.get(@errors, :quiet_end, [])}
          />
          <.input
            type="select"
            id="push-time_zone"
            name="time_zone"
            value={@params["time_zone"]}
            label={gettext("Time zone")}
            prompt={gettext("Choose a time zone")}
            options={@zone_options}
            errors={Map.get(@errors, :time_zone, [])}
          />
        </div>
        <div>
          <.button id="push-quiet-hours-save" type="submit">{gettext("Save")}</.button>
        </div>
      </form>
    </.settings_card>
    """
  end
end
