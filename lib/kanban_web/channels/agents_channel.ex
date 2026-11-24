defmodule KanbanWeb.AgentsChannel do
  @moduledoc """
  The app's `me:agents` channel on `KanbanWeb.UserSocket` (W2766,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7): the Agents tab's
  roster and goal progress, live. docs/api/me_channels.md is the app's
  contract.

  On join (gated by `KanbanWeb.MeChannel.authorize_join/1`) it subscribes to
  `"agents:<id>"` (`Kanban.Tasks.Broadcaster.broadcast_agent_event/3`) and to
  `"board:<id>"` for every board the person can access in any workspace that
  the plan unlocks, and to the person's notification and board-access topics
  (`KanbanWeb.MeChannel.subscribe_person/1`), then pushes `"agents"` with the
  full roster and goal progress.

  An `{:agent_event, _}` on a board's agents topic (a task created, claimed,
  completed or reviewed), a `{Kanban.Boards, :members_changed, board_id}`
  broadcast on its board topic, a `board_access_changed` notification, or a
  `{Kanban.Boards, :access_gained, board_ids}` signal naming a board the
  channel does not cover yet (`Kanban.Boards.AccessSignal`, D466: a gain
  that sends no notification, such as a board moved into the person's
  Organization) asks for a rebuild, coalesced to one per second
  (`KanbanWeb.Coalescer`).
  The board topic is subscribed for `members_changed` alone: it is the only
  signal for an access loss that sends no notification, such as an org-admin
  removed from the Organization or a SCIM deprovisioning (D460). Every other
  message on it, and every other notification, is ignored. A rebuild first
  checks the device, the user and the plan again
  (`KanbanWeb.MeChannel.check_access/1`) and stops the channel when they
  fail, then re-reads the person's boards and re-subscribes both topics,
  dropping the boards they lost, then reads `Kanban.Agents.list_agents_for_app/2`
  in the device's time zone and renders it with
  `KanbanWeb.API.Me.AgentJSON.index/1`, so the push is exactly what
  `GET /api/me/agents` returns for the same device. It pushes only when that
  full state differs from the last one pushed, and never a partial diff.
  """
  use KanbanWeb, :channel

  alias Kanban.Agents
  alias Kanban.Notifications.Notification
  alias KanbanWeb.API.Me.AgentJSON
  alias KanbanWeb.MeChannel

  @topics ["agents", "board"]

  @impl true
  def join("me:agents", _params, socket), do: MeChannel.authorize_join(socket)

  @impl true
  def handle_info(:after_join, socket) do
    {:noreply,
     socket |> MeChannel.subscribe_person() |> MeChannel.sync_boards(@topics) |> push_agents()}
  end

  def handle_info(:rebuild, socket) do
    case socket |> MeChannel.rebuild_arrived() |> MeChannel.check_access() do
      {:ok, socket} ->
        {:noreply, socket |> MeChannel.sync_boards(@topics) |> push_agents()}

      {:error, _refused} ->
        {:stop, :normal, socket}
    end
  end

  def handle_info({:agent_event, _event}, socket),
    do: {:noreply, MeChannel.request_rebuild(socket)}

  def handle_info({Kanban.Boards, :members_changed, _board_id}, socket),
    do: {:noreply, MeChannel.request_rebuild(socket)}

  def handle_info({Kanban.Boards, :access_gained, board_ids}, socket),
    do: {:noreply, MeChannel.access_gained(socket, board_ids)}

  def handle_info(
        {:notification_created, %Notification{event_type: :board_access_changed}},
        socket
      ),
      do: {:noreply, MeChannel.request_rebuild(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp push_agents(%{assigns: %{current_scope: scope, current_device: device}} = socket) do
    overview = Agents.list_agents_for_app(scope, timezone: time_zone(device))
    MeChannel.push_changed(socket, "agents", AgentJSON.index(%{overview: overview}))
  end

  defp time_zone(%{time_zone: zone}) when is_binary(zone), do: zone
  defp time_zone(_device), do: nil
end
