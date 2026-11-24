defmodule KanbanWeb.InboxChannel do
  @moduledoc """
  The app's `me:inbox` channel on `KanbanWeb.UserSocket` (W2766,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7): the Now screen's
  decisions, live. docs/api/me_channels.md is the app's contract.

  On join (gated by `KanbanWeb.MeChannel.authorize_join/1`) it subscribes to
  the person's notification and board-access topics
  (`KanbanWeb.MeChannel.subscribe_person/1`) and to `"board:<id>"` for every
  board they can access in any workspace that the plan unlocks
  (`KanbanWeb.MeChannel.sync_boards/2`), then pushes `"decisions"` with the
  full list.

  Any message on those topics (a task change, a membership change, a new or
  read notification) asks for a rebuild, except a
  `{Kanban.Boards, :access_gained, board_ids}` signal
  (`Kanban.Boards.AccessSignal`, D466) whose boards the channel already
  covers. Rebuilds are coalesced to one per second
  (`KanbanWeb.Coalescer`). A rebuild first checks the device, the user and the plan again
  (`KanbanWeb.MeChannel.check_access/1`) and stops the channel when they
  fail, then re-reads the person's boards and
  re-subscribes, so a `board_access_changed` notification or a
  `{Kanban.Boards, :members_changed, board_id}` broadcast drops a board the
  person lost and adds one they gained; it then builds the decisions with
  `Kanban.Decisions.build_with_summary/2` and `source: :channel` (emitting
  `[:kanban, :decisions, :built]` with that source) and renders them with
  `KanbanWeb.API.Me.DecisionJSON.index/1`, so the push is exactly what
  `GET /api/me/decisions` returns for the same device. It pushes only when
  that full list differs from the last one pushed, and never a partial diff.
  """
  use KanbanWeb, :channel

  alias Kanban.Decisions
  alias KanbanWeb.API.Me.DecisionJSON
  alias KanbanWeb.MeChannel

  @impl true
  def join("me:inbox", _params, socket), do: MeChannel.authorize_join(socket)

  @impl true
  def handle_info(:after_join, socket) do
    {:noreply,
     socket |> MeChannel.subscribe_person() |> MeChannel.sync_boards("board") |> push_decisions()}
  end

  def handle_info(:rebuild, socket) do
    case socket |> MeChannel.rebuild_arrived() |> MeChannel.check_access() do
      {:ok, socket} ->
        {:noreply, socket |> MeChannel.sync_boards("board") |> push_decisions()}

      {:error, _refused} ->
        {:stop, :normal, socket}
    end
  end

  def handle_info({Kanban.Boards, :access_gained, board_ids}, socket),
    do: {:noreply, MeChannel.access_gained(socket, board_ids)}

  def handle_info(_change, socket), do: {:noreply, MeChannel.request_rebuild(socket)}

  defp push_decisions(%{assigns: %{current_scope: scope, current_device: device}} = socket) do
    decisions =
      Decisions.build_with_summary(scope, source: :channel, device_class: device.device_class)

    MeChannel.push_changed(socket, "decisions", DecisionJSON.index(%{decisions: decisions}))
  end
end
