defmodule KanbanWeb.TaskLive.Form.RelationalScopes do
  @moduledoc """
  Board-scope checks for the task edit form's relational fields, extracted
  from `KanbanWeb.TaskLive.FormComponent` (which sits at the module-size limit
  in `AGENTS.md`).

  Every relational field a user can change through the form must live on the
  current board: `column_id`, `parent_id` and `assigned_to_id`. Each check is
  independent; the first failure rejects the save with a targeted changeset
  error. Label ids are resolved separately by
  `KanbanWeb.TaskLive.Form.LabelSelection`.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.Form.TaskParams

  @doc """
  Returns `:ok` when every submitted relational field belongs to `board`, or
  `{:error, field, message}` for the first one that does not. Blank and
  absent fields pass.
  """
  def validate(task_params, board) do
    with :ok <- validate_column_scope(task_params, board),
         :ok <- validate_parent_scope(task_params, board) do
      validate_assigned_to_scope(task_params, board)
    end
  end

  defp validate_column_scope(task_params, board) do
    case Map.get(task_params, "column_id") do
      nil ->
        :ok

      "" ->
        :ok

      column_id ->
        column = Columns.get_column!(column_id)

        if column.board_id == board.id do
          :ok
        else
          {:error, :column_id, gettext("Column does not belong to this board")}
        end
    end
  end

  defp validate_parent_scope(task_params, board) do
    case Map.get(task_params, "parent_id") do
      nil ->
        :ok

      "" ->
        :ok

      parent_id_input ->
        with {:ok, parent_id} <- TaskParams.coerce_id(parent_id_input),
             %{} <- Tasks.get_task_for_board(parent_id, board.id) do
          :ok
        else
          _ -> {:error, :parent_id, gettext("Parent goal does not belong to this board")}
        end
    end
  end

  defp validate_assigned_to_scope(task_params, board) do
    case Map.get(task_params, "assigned_to_id") do
      nil ->
        :ok

      "" ->
        :ok

      assigned_input ->
        with {:ok, user_id} <- TaskParams.coerce_id(assigned_input),
             true <- board_member?(board, user_id) do
          :ok
        else
          _ -> {:error, :assigned_to_id, gettext("Assignee does not have access to this board")}
        end
    end
  end

  # Called from validate_assigned_to_scope/2; analyzer regex misses predicate `?` callers.
  defp board_member?(board, user_id) do
    not is_nil(Kanban.Boards.get_user_access(board.id, user_id))
  end
end
