defmodule KanbanWeb.BoardLive.BoardEvents do
  @moduledoc """
  Handles the messages broadcast on a board's `"board:<id>"` PubSub topic for
  `KanbanWeb.BoardLive.Show`, which subscribes once connected
  (`KanbanWeb.BoardLive.Params`) and hands every message it does not handle
  itself to `handle/2`.

  Task changes reload the board's columns and cards, except while
  `:skip_next_reload` is set (this view just saved the task itself). A label
  change reloads the cards too, since they render the label chips, refreshes
  the filter bar's options, and rebuilds an open task form's label picker; a
  membership change, which can unassign a removed member's tasks, reloads the
  cards and the filter bar too. Either one drops a filter naming a label or
  member that is gone, re-rendering the cards and correcting the URL, so the
  board never shows a filtered view its controls no longer describe. A column
  change re-renders every column. Comment changes go straight to the open
  comment thread.

  There is deliberately no catch-all clause: an unknown message is a bug in a
  broadcaster, not something to swallow.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update: 2]

  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.TaskLive.CommentThreadComponent
  alias KanbanWeb.TaskLive.FormComponent

  @doc """
  Applies one board-topic message to the socket, returning `{:noreply, socket}`.
  """
  def handle({Kanban.Labels, :labels_changed, _board_id}, socket) do
    refresh_open_task_form(socket.assigns)
    {socket, filters_changed?} = FilterActions.refresh_options(socket, socket.assigns.board)
    {:noreply, socket} = BoardState.reload_board_data(socket)
    {:noreply, maybe_sync_url(socket, filters_changed?)}
  end

  # Removing a member also unassigns them from the board's open tasks, so the
  # cards' assignees can change too.
  def handle({Kanban.Boards, :members_changed, _board_id}, socket) do
    {socket, filters_changed?} = FilterActions.refresh_options(socket, socket.assigns.board)
    {:noreply, socket} = BoardState.reload_board_data(socket)
    {:noreply, maybe_sync_url(socket, filters_changed?)}
  end

  def handle({Kanban.Columns, :columns_changed, _board_id}, socket),
    do: BoardState.reload_columns(socket)

  def handle({Kanban.Tasks, :task_moved, task}, socket),
    do: BoardState.handle_remote_task_move(socket, task)

  def handle({Kanban.Tasks, :task_created, _task}, socket),
    do: BoardState.reload_board_data(socket)

  def handle({Kanban.Tasks, event, _task}, socket)
      when event in [:task_updated, :task_deleted, :task_status_changed, :task_reviewed],
      do: reload_unless_skipped(socket)

  # The simple-format events the API paths broadcast.
  def handle({event, _task}, socket)
      when event in [:task_updated, :task_moved_to_review, :task_completed],
      do: BoardState.reload_board_data(socket)

  # The board columns render no comments; the comment thread inside the task
  # view and task edit modals does, so forward the change to it. refresh/1
  # targets the thread component directly (never ViewComponent, whose
  # permission assigns a partial send_update would reset) and skips a thread
  # that is not open.
  def handle({Kanban.Tasks.Comments, :comment_changed, payload}, socket) do
    CommentThreadComponent.refresh(payload)
    {:noreply, socket}
  end

  def handle({:field_visibility_updated, new_visibility}, socket),
    do: {:noreply, assign(socket, :field_visibility, new_visibility)}

  # The open task form's label picker would otherwise keep offering, and
  # keep ticked, a label that was just deleted.
  defp refresh_open_task_form(%{live_action: action}) when action in [:new_task, :new_goal],
    do: send_update(FormComponent, id: :new, refresh_labels: true)

  defp refresh_open_task_form(%{live_action: action, task: %{id: id}})
       when action in [:edit_task, :edit_task_in_column],
       do: send_update(FormComponent, id: "edit-#{id}", refresh_labels: true)

  defp refresh_open_task_form(_assigns), do: :ok

  defp maybe_sync_url(socket, true), do: FilterActions.sync_url(socket)
  defp maybe_sync_url(socket, false), do: socket

  defp reload_unless_skipped(socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end
end
