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
  cards and the filter bar too, after re-reading the viewer's own access; a
  viewer it removed is sent back to `/boards`. Either one drops a filter naming a label or
  member that is gone, re-rendering the cards and correcting the URL, so the
  board never shows a filtered view its controls no longer describe. A
  membership change also refreshes an open members screen, whose free-board cap
  line depends on the board's plan (a board move changes it), and for the same
  reason makes the open task's Attachments section, its comment thread and an
  open task form re-read the plan. A column
  change re-renders every column. A deleted task that is open in the task view
  or an edit form closes it, with a flash when the delete came from elsewhere. Comment changes go straight to the open
  comment thread. Attachment changes refresh the open task's Attachments
  section and its comment thread, which lists each comment's files; the
  board columns render no attachments, so they are not reloaded.

  There is deliberately no catch-all clause: an unknown message is a bug in a
  broadcaster, not something to swallow.
  """
  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3, send_update: 2]

  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.BoardLive.MembersFormComponent
  alias KanbanWeb.BoardLive.Params
  alias KanbanWeb.TaskLive.AttachmentsComponent
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
  # cards' assignees can change too. The viewer's own access is re-read first:
  # a viewer the change removed leaves the board, exactly as if they had opened
  # it without access, unless it is a public read-only board they may still
  # read (W2218).
  def handle({Kanban.Boards, :members_changed, _board_id}, socket) do
    socket = BoardState.refresh_access(socket)

    if lost_access?(socket.assigns) do
      Params.handle_board_not_found(socket)
    else
      refresh_members_screen(socket.assigns)
      refresh_plan_gated(socket.assigns)
      {socket, filters_changed?} = FilterActions.refresh_options(socket, socket.assigns.board)
      {:noreply, socket} = BoardState.reload_board_data(socket)
      {:noreply, maybe_sync_url(socket, filters_changed?)}
    end
  end

  def handle({Kanban.Columns, :columns_changed, _board_id}, socket),
    do: BoardState.reload_columns(socket)

  def handle({Kanban.Tasks, :task_moved, task}, socket),
    do: BoardState.handle_remote_task_move(socket, task)

  def handle({Kanban.Tasks, :task_created, _task}, socket),
    do: BoardState.reload_board_data(socket)

  # A deleted task takes its attachments and comments with it through the
  # cascade, which broadcasts nothing else, so a view or form still open on
  # it would keep showing a task whose files and actions are all gone.
  def handle({Kanban.Tasks, :task_deleted, task}, socket),
    do: socket |> close_deleted_task(task) |> reload_unless_skipped()

  def handle({Kanban.Tasks, event, _task}, socket)
      when event in [:task_updated, :task_status_changed, :task_reviewed],
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

  # Kanban.Attachments broadcasts every create and delete. The board columns
  # render no attachments; the Attachments section inside the task view
  # does, and so does the comment thread, which lists each comment's files,
  # so forward the change to both the same way as a comment change.
  def handle({Kanban.Attachments, :attachment_changed, payload}, socket) do
    AttachmentsComponent.refresh(payload)
    CommentThreadComponent.refresh(payload)
    {:noreply, socket}
  end

  def handle({:field_visibility_updated, new_visibility}, socket),
    do: {:noreply, assign(socket, :field_visibility, new_visibility)}

  # The open task form's label picker would otherwise keep offering, and
  # keep ticked, a label that was just deleted.
  defp refresh_open_task_form(assigns), do: update_open_task_form(assigns, refresh_labels: true)

  defp update_open_task_form(%{live_action: action}, update)
       when action in [:new_task, :new_goal],
       do: send_update(FormComponent, [id: :new] ++ update)

  defp update_open_task_form(%{live_action: action, task: %{id: id}}, update)
       when action in [:edit_task, :edit_task_in_column],
       do: send_update(FormComponent, [id: "edit-#{id}"] ++ update)

  defp update_open_task_form(_assigns, _update), do: :ok

  # A board moved into or out of an Organization changes plan, and nothing
  # else an open surface holds changes with it, so no re-render would reach
  # its plan-gated controls: the open task's Attachments section and comment
  # thread re-read the plan, and so does an open task form (its Attachments
  # field and the paid telemetry fields).
  defp refresh_plan_gated(assigns) do
    update_open_task_form(assigns, refresh_plan: true)

    for task_id <- open_task_ids(assigns) do
      AttachmentsComponent.refresh(task_id)
      CommentThreadComponent.refresh(task_id)
    end

    :ok
  end

  defp open_task_ids(assigns) do
    edited =
      if assigns[:live_action] in [:edit_task, :edit_task_in_column],
        do: assigns[:task] && assigns.task.id

    Enum.uniq(for id <- [assigns[:viewing_task_id], edited], is_integer(id), do: id)
  end

  defp lost_access?(%{user_access: nil, board: %{read_only: read_only}}), do: read_only != true
  defp lost_access?(_assigns), do: false

  defp maybe_sync_url(socket, true), do: FilterActions.sync_url(socket)
  defp maybe_sync_url(socket, false), do: socket

  defp close_deleted_task(socket, %{id: id}) when is_integer(id) do
    case open_on(socket.assigns, id) do
      :view -> socket |> assign(viewing_task_id: nil, show_task_modal: false) |> deleted_flash()
      :form -> socket |> push_patch(to: ~p"/boards/#{socket.assigns.board}") |> deleted_flash()
      nil -> socket
    end
  end

  defp close_deleted_task(socket, _task), do: socket

  defp open_on(%{viewing_task_id: id}, id), do: :view

  defp open_on(%{live_action: action, task: %{id: id}}, id)
       when action in [:edit_task, :edit_task_in_column],
       do: :form

  defp open_on(_assigns, _id), do: nil

  # This view's own delete flashes its own message (and sets
  # :skip_next_reload); a delete made elsewhere is explained here.
  defp deleted_flash(socket) do
    if socket.assigns[:skip_next_reload],
      do: socket,
      else: put_flash(socket, :info, gettext("This task was deleted."))
  end

  defp reload_unless_skipped(socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end

  # An open members screen re-reads the board and its members, so a change made
  # elsewhere shows without a reload: moving the board into an Organization
  # workspace (W2218) makes it a paid board, and the free-board cap line goes.
  defp refresh_members_screen(%{live_action: :manage_members, board: board, current_scope: scope}) do
    case Kanban.Boards.get_board(board.id, scope.user) do
      {:ok, fresh} ->
        send_update(MembersFormComponent,
          id: "board-members-#{board.id}",
          board: fresh,
          current_scope: scope
        )

      {:error, :not_found} ->
        :ok
    end
  end

  defp refresh_members_screen(_assigns), do: :ok
end
