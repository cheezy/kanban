defmodule KanbanWeb.BoardLive.Authorization do
  @moduledoc """
  Access-control helpers for `KanbanWeb.BoardLive.Show`, extracted from the
  LiveView (W1447). Covers column-page action authorization, task-modify
  authorization, and the move-target authorization + dispatch path.

  These are security controls: every check that decides allow/deny is moved
  byte-identical from the LiveView. The column-action checks take
  `(live_action, user_access, board)` and return `:ok | {:error, message}` (the
  caller renders the flash); the task/move checks take the socket and return
  `{:ok, ...} | {:error, :not_authorized | :not_found}` (the caller renders the
  flash). `dispatch_authorized_move/5` and the id parsing call back into
  `KanbanWeb.BoardLive.Show` for helpers shared with code that stays in the
  LiveView (`parse_task_id/1`, `handle_task_reorder/4`, `handle_task_move/4`).
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.BoardLive.Show

  require Logger

  @doc "Gates column create/edit page actions; returns :ok or {:error, flash}."
  def check_column_action_authorization(live_action, user_access, board)
      when live_action in [:new_column, :edit_column] do
    cond do
      user_access != :owner ->
        {:error, gettext("Only the board owner can manage columns")}

      live_action == :new_column and board.ai_optimized_board ->
        {:error, gettext("Cannot add columns to AI optimized boards")}

      live_action == :edit_column and board.ai_optimized_board ->
        {:error, gettext("Cannot edit columns on AI optimized boards")}

      true ->
        :ok
    end
  end

  def check_column_action_authorization(_live_action, _user_access, _board), do: :ok

  @doc "Gates the new-column and manage-members views; returns :ok or {:error, flash}."
  def check_new_column_authorization(:new_column, user_access, board) do
    cond do
      user_access != :owner ->
        {:error, gettext("Only the board owner can create columns")}

      board.ai_optimized_board ->
        {:error, gettext("Cannot add columns to AI optimized boards")}

      true ->
        :ok
    end
  end

  # Defense-in-depth for W1434: keep the :manage_members view (and the member
  # list / search component it renders) owner-only, so a non-owner who navigates
  # straight to /boards/:id/members is redirected away rather than reaching the
  # MembersFormComponent. The search handler itself is independently gated in
  # KanbanWeb.BoardLive.Membership.search_user/3.
  def check_new_column_authorization(:manage_members, user_access, _board)
      when user_access != :owner do
    {:error, gettext("Only the board owner can manage board membership")}
  end

  def check_new_column_authorization(_live_action, _user_access, _board), do: :ok

  @doc "Authorizes a modify action on a task; requires :can_modify assign."
  def authorize_modify_for_task(socket, raw_id) do
    if socket.assigns.can_modify do
      lookup_task_for_board(socket, raw_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_task_for_board(socket, raw_id) do
    with {:ok, id} <- Show.parse_task_id(raw_id),
         %{} = task <- Tasks.get_task_for_board(id, socket.assigns.board.id) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Dispatches an already-authorized move to reorder or cross-column move."
  def dispatch_authorized_move(socket, task, old_col_id, new_col_id, new_position) do
    Logger.info(
      "Move task event: task_id=#{task.id}, old_column=#{old_col_id}, new_column=#{new_col_id}, new_position=#{new_position}"
    )

    if old_col_id == new_col_id do
      Show.handle_task_reorder(socket, old_col_id, task.id, new_position)
    else
      Show.handle_task_move(socket, task, new_col_id, new_position)
    end
  end

  @doc "Authorizes a move; requires :can_modify and board-scoped move targets."
  def authorize_move_task(socket, raw_task_id, raw_old_col_id, raw_new_col_id) do
    if socket.assigns.can_modify do
      lookup_move_targets(socket, raw_task_id, raw_old_col_id, raw_new_col_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_move_targets(socket, raw_task_id, raw_old_col_id, raw_new_col_id) do
    board_id = socket.assigns.board.id

    with {:ok, ids} <- parse_move_ids(raw_task_id, raw_old_col_id, raw_new_col_id),
         {:ok, task} <- fetch_move_targets(board_id, ids) do
      {task_id, old_col_id, new_col_id} = ids
      _ = task_id
      {:ok, task, old_col_id, new_col_id}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_move_ids(raw_task_id, raw_old_col_id, raw_new_col_id) do
    with {:ok, task_id} <- Show.parse_task_id(raw_task_id),
         {:ok, old_col_id} <- Show.parse_task_id(raw_old_col_id),
         {:ok, new_col_id} <- Show.parse_task_id(raw_new_col_id) do
      {:ok, {task_id, old_col_id, new_col_id}}
    end
  end

  # Re-validates the task AND both columns are scoped to board_id (W392
  # cross-board IDOR guard). The with/short-circuit behavior is security-load-
  # bearing and moved byte-identical.
  defp fetch_move_targets(board_id, {task_id, old_col_id, new_col_id}) do
    with %{} = task <- Tasks.get_task_for_board(task_id, board_id),
         %{} <- Columns.get_column_for_board(old_col_id, board_id),
         %{} <- Columns.get_column_for_board(new_col_id, board_id) do
      {:ok, task}
    else
      _ -> :error
    end
  end
end
