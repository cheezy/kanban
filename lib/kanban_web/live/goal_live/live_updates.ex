defmodule KanbanWeb.GoalLive.LiveUpdates do
  @moduledoc """
  Keeps `KanbanWeb.GoalLive.Show` live: it subscribes the page to its board's
  `"board:<id>"` PubSub topic once connected and decides what each message on
  that topic means for the open goal.

  A change to the goal or to one of its children schedules a reload; the page
  reloads through the same calls its mount uses, never from the broadcast
  payload, so the board access and field visibility rules still apply. An
  agent completing a task sends several events in a row, so one reload is
  scheduled 100 ms after the first and every event that arrives while it
  is pending is absorbed by it.

  A column change reloads too, since the sections are grouped by column name.
  A membership change re-reads the viewer's access straight away; a viewer it
  removed is unsubscribed and sent back to `/boards`. The goal being deleted
  sends the viewer to the board with a flash. Every other message on the
  topic (labels, comments, attachments, field visibility, changes to tasks
  outside the goal) is ignored.
  """
  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_navigate: 2, put_flash: 3]

  alias Kanban.Boards

  @refresh_delay_ms 100

  # The `{event, task}` shapes the agent API paths broadcast (claim, unclaim,
  # dependencies, completion, review). `:task_returned_to_doing` has no
  # handler on the board page, but it moves a child, so the goal page needs it.
  @simple_task_events [
    :task_updated,
    :task_moved_to_review,
    :task_completed,
    :task_returned_to_doing
  ]

  @doc """
  Subscribes the socket to the board's topic when it is connected (never on
  the static render) and sets the assigns `handle/2` relies on.
  """
  def subscribe(socket, board_id) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Kanban.PubSub, topic(board_id))

    socket
    |> assign(:refresh_scheduled?, false)
    |> assign(:goal_gone?, false)
  end

  @doc """
  Applies one board-topic message to the socket and returns the socket. The
  reload itself is the `:refresh_goal` message this schedules, which the view
  handles.
  """
  def handle(_message, %{assigns: %{goal_gone?: true}} = socket), do: socket

  def handle({Kanban.Tasks, :task_deleted, %{id: id}}, %{assigns: %{goal: %{id: id}}} = socket),
    do: goal_deleted(socket)

  def handle({Kanban.Tasks, _event, task}, socket), do: refresh_if_affected(socket, task)

  def handle({event, task}, socket) when event in @simple_task_events,
    do: refresh_if_affected(socket, task)

  def handle({Kanban.Columns, :columns_changed, _board_id}, socket),
    do: schedule_refresh(socket)

  def handle({Kanban.Boards, :members_changed, _board_id}, socket),
    do: recheck_access(socket)

  def handle(_message, socket), do: socket

  @doc """
  Returns true when a broadcast task is the goal itself or one of its
  children: its `parent_id` is the goal's id, or it is a child the page shows
  now (a child moved to another goal carries its new `parent_id`, and the
  page still has to drop it). Anything that is not a task is false.
  """
  def affects_goal?(%{goal: %{id: goal_id}} = view, %{id: id, parent_id: parent_id}) do
    id == goal_id or parent_id == goal_id or shown_child?(view, id)
  end

  def affects_goal?(_view, _task), do: false

  @doc """
  Clears the pending-reload flag; the view calls it when `:refresh_goal`
  arrives, before it reloads.
  """
  def refreshed(socket), do: assign(socket, :refresh_scheduled?, false)

  @doc """
  Leaves the page because the goal is gone, for a viewer who may still read
  the board: unsubscribes, flashes and navigates to the board.
  """
  def goal_deleted(socket) do
    socket
    |> leave()
    |> put_flash(:info, gettext("This goal was deleted."))
    |> push_navigate(to: ~p"/boards/#{socket.assigns.board}")
  end

  @doc """
  Leaves the page because the viewer can no longer read the board:
  unsubscribes, flashes and navigates to `/boards`, as mount does for a
  viewer without access.
  """
  def access_lost(socket) do
    socket
    |> leave()
    |> put_flash(:error, gettext("Goal not found"))
    |> push_navigate(to: ~p"/boards")
  end

  defp refresh_if_affected(socket, task) do
    if affects_goal?(socket.assigns, task), do: schedule_refresh(socket), else: socket
  end

  defp schedule_refresh(%{assigns: %{refresh_scheduled?: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh_goal, @refresh_delay_ms)
    assign(socket, :refresh_scheduled?, true)
  end

  defp recheck_access(socket) do
    %{board: board, current_scope: %{user: user}} = socket.assigns

    case Boards.get_board(board.id, user) do
      {:ok, _board} -> schedule_refresh(socket)
      {:error, _reason} -> access_lost(socket)
    end
  end

  defp leave(socket) do
    Phoenix.PubSub.unsubscribe(Kanban.PubSub, topic(socket.assigns.board.id))
    assign(socket, :goal_gone?, true)
  end

  defp shown_child?(%{children: children}, id) when is_list(children),
    do: Enum.any?(children, &(&1.id == id))

  defp shown_child?(_view, _id), do: false

  defp topic(board_id), do: "board:#{board_id}"
end
