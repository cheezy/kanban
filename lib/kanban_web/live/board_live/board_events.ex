defmodule KanbanWeb.BoardLive.BoardEvents do
  @moduledoc """
  Handles the messages broadcast on a board's `"board:<id>"` PubSub topic for
  `KanbanWeb.BoardLive.Show`, which subscribes once connected
  (`KanbanWeb.BoardLive.Params`) and hands every message it does not handle
  itself to `handle/2`.

  Task changes reload the board's columns and cards, except while
  `:skip_next_reload` is set (this view just saved the task itself). A label
  change reloads the cards too, since they render the label chips, and
  refreshes the filter bar's options; a membership change refreshes only the
  options. Either one drops a filter naming a label or member that is gone,
  re-rendering the cards and correcting the URL, so the board never shows a
  filtered view its controls no longer describe. Comment changes go straight to the open comment thread.

  There is deliberately no catch-all clause: an unknown message is a bug in a
  broadcaster, not something to swallow.
  """
  import Phoenix.Component, only: [assign: 3]

  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.TaskLive.CommentThreadComponent

  @doc """
  Applies one board-topic message to the socket, returning `{:noreply, socket}`.
  """
  def handle({Kanban.Labels, :labels_changed, _board_id}, socket) do
    {socket, filters_changed?} = FilterActions.refresh_options(socket, socket.assigns.board)
    {:noreply, socket} = BoardState.reload_board_data(socket)
    {:noreply, maybe_sync_url(socket, filters_changed?)}
  end

  def handle({Kanban.Boards, :members_changed, _board_id}, socket) do
    case FilterActions.refresh_options(socket, socket.assigns.board) do
      {socket, false} ->
        {:noreply, socket}

      {socket, true} ->
        {:noreply, socket} = BoardState.reload_board_data(socket)
        {:noreply, FilterActions.sync_url(socket)}
    end
  end

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

  defp maybe_sync_url(socket, true), do: FilterActions.sync_url(socket)
  defp maybe_sync_url(socket, false), do: socket

  defp reload_unless_skipped(socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end
end
