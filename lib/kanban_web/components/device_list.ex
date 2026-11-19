defmodule KanbanWeb.Components.DeviceList do
  @moduledoc """
  A list of the phones and tablets a person is signed in to Stride on, each
  with a Revoke button, for the Devices section of `/users/settings` and a
  member's devices in the org console's Members section (`/org`)
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1 "Who sees devices").

  A row shows the device's name, platform, class, app version and when it was
  last seen. It never shows a token, a hash, the push token or the approval
  key: the list renders only the fields named here.

  The Revoke button sends `revoke_event` with the device id as `device_id`,
  so each page handles the revoke through its own context call. Colours are
  the `.stride-screen` ink and line tokens, defined for light and dark mode.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.CoreComponents, only: [button: 1]
  import KanbanWeb.LocalTimeComponent, only: [local_time: 1]

  alias Kanban.Devices.Device

  attr :id, :string, required: true, doc: "the list's DOM id; the empty state is <id>-empty"
  attr :id_prefix, :string, required: true, doc: "prefix for each row's and button's DOM id"
  attr :devices, :list, required: true, doc: "the devices, as Kanban.Devices.Device structs"
  attr :revoke_event, :string, required: true, doc: "the event the Revoke button sends"
  attr :revoke_confirm, :string, required: true, doc: "the Revoke button's confirmation text"
  attr :empty_text, :string, required: true, doc: "shown when there are no devices"
  attr :target, :any, default: nil, doc: "the phx-target for the Revoke button"

  def device_list(assigns) do
    ~H"""
    <p
      :if={@devices == []}
      id={"#{@id}-empty"}
      style="margin: 0; padding: 10px 0; font-size: 13px; color: var(--ink-2); line-height: 1.55;"
    >
      {@empty_text}
    </p>
    <ul :if={@devices != []} id={@id} style="list-style: none; margin: 0; padding: 0;">
      <li
        :for={device <- @devices}
        id={"#{@id_prefix}-#{device.id}"}
        class="flex flex-col gap-1 @md:flex-row @md:items-center @md:gap-4"
        style="padding: 10px 0; border-bottom: 1px solid var(--line);"
      >
        <span class="@md:flex-1 min-w-0" style="display: flex; flex-direction: column; gap: 2px;">
          <span
            id={"#{@id_prefix}-name-#{device.id}"}
            style="font-size: 13px; font-weight: 500; color: var(--ink); overflow-wrap: anywhere;"
          >
            {device.name}
          </span>
          <span
            id={"#{@id_prefix}-kind-#{device.id}"}
            style="font-size: 12px; color: var(--ink-2);"
          >
            {kind(device)}
          </span>
        </span>
        <span
          id={"#{@id_prefix}-version-#{device.id}"}
          class="@md:w-32 @md:flex-shrink-0"
          style="font-size: 12px; font-family: var(--font-mono); color: var(--ink-2); overflow-wrap: anywhere;"
        >
          {version(device)}
        </span>
        <span
          id={"#{@id_prefix}-last-seen-#{device.id}"}
          class="@md:w-44 @md:flex-shrink-0"
          style="font-size: 12px; color: var(--ink-2);"
        >
          {gettext("Last seen")}
          <.local_time :if={device.last_seen_at} value={device.last_seen_at} style={:short_datetime} />
          <span :if={is_nil(device.last_seen_at)}>{gettext("Never")}</span>
        </span>
        <span class="flex @md:w-24 @md:flex-shrink-0 @md:justify-end">
          <.button
            id={"#{@id_prefix}-revoke-#{device.id}"}
            type="button"
            phx-click={@revoke_event}
            phx-value-device_id={device.id}
            phx-target={@target}
            data-confirm={@revoke_confirm}
            class="btn btn-soft btn-sm"
          >
            {gettext("Revoke")}
          </.button>
        </span>
      </li>
    </ul>
    """
  end

  @doc "The translated label for a device's platform and class, e.g. \"iOS · Phone\"."
  @spec kind(Device.t()) :: String.t()
  def kind(%Device{platform: platform, device_class: device_class}) do
    [platform_label(platform), class_label(device_class)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "The translated app version line, or a dash when the app sent none."
  @spec version(Device.t()) :: String.t()
  def version(%Device{app_version: version}) when is_binary(version) and version != "",
    do: gettext("App %{version}", version: version)

  def version(%Device{}), do: "—"

  defp platform_label(:ios), do: gettext("iOS")
  defp platform_label(:android), do: gettext("Android")
  defp platform_label(_other), do: nil

  defp class_label(:phone), do: gettext("Phone")
  defp class_label(:tablet), do: gettext("Tablet")
  defp class_label(_other), do: nil
end
