defmodule KanbanWeb.API.Me.NotificationSettingsJSON do
  @moduledoc """
  Renders the person's push settings for `GET` and `PUT
  /api/me/notification_settings`, the `NotificationSettings` schema in
  `priv/openapi/stride-api.json`. The eight switches are keyed by event type,
  decisions first; quiet-hours times are `"HH:MM"`.
  """

  alias Kanban.Notifications.PushSettings

  def show(%{settings: settings}), do: %{data: settings(settings)}

  @doc false
  def settings(settings) do
    %{
      mode: settings.mode,
      switches: Map.new(PushSettings.push_events(), &{&1, Map.fetch!(settings.switches, &1)}),
      quiet_hours_enabled: settings.quiet_hours_enabled,
      quiet_start: hh_mm(settings.quiet_start),
      quiet_end: hh_mm(settings.quiet_end),
      time_zone: settings.time_zone
    }
  end

  defp hh_mm(%Time{} = time), do: time |> Time.to_iso8601() |> binary_part(0, 5)
end
