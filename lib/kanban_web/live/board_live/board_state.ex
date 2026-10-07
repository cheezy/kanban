defmodule KanbanWeb.BoardLive.BoardState do
  @moduledoc """
  Board, column and task loading for `KanbanWeb.BoardLive.Show`, extracted from
  the LiveView to keep it under the module-size guideline. Assigns the common
  board state, loads every column's tasks together with the goal-derived
  assigns, and re-reads them after a change. Moved unchanged: the stream-reset
  choices in each reload are deliberate (see the comments on each).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 3, stream: 4]

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.BoardAccent
  alias KanbanWeb.BoardLive.Goals

  @doc false
  def assign_common_board_state(socket, board, user_access, columns) do
    user = socket.assigns.current_scope.user
    board_with_metrics = put_board_metrics(board, user)

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:board, board_with_metrics)
    |> assign(:user_access, user_access)
    |> assign(:can_modify, user_access in [:owner, :modify])
    |> assign(:is_owner, user_access == :owner)
    |> assign(:field_visibility, board.field_visibility || %{})
    |> assign(:has_columns, not Enum.empty?(columns))
    |> stream(:columns, columns, reset: true)
    |> load_tasks_for_columns(columns)
  end

  # Attach the per-board metrics map AND the members list to the board
  # struct so the BoardHeader sub-band can render the in-flight/in-
  # review/shipped counts plus an avatar stack of everyone on the
  # board to the right of the stats. Falls back to an empty metrics
  # map (zeros) and an empty member list when the user can't read
  # them, which BoardHeader handles via Map.get fallbacks.
  def put_board_metrics(board, user) do
    board =
      case Boards.get_board_metrics(user, board.id) do
        {:ok, metrics} -> %{board | metrics: metrics}
        {:error, _} -> board
      end

    board = %{board | members: Boards.list_board_members(board.id)}
    Map.put(board, :accent, BoardAccent.for_board(board, user))
  end

  def assign_board_state(socket, board, user_access) do
    columns = Columns.list_columns(board)

    {:noreply, assign_common_board_state(socket, board, user_access, columns)}
  end

  def reload_board_columns(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  def page_title(:show), do: "Stride"
  def page_title(:new_column), do: "New column"
  def page_title(:edit_column), do: "Edit Column"
  def page_title(:new_task), do: "Stride"
  def page_title(:new_goal), do: "Stride"
  def page_title(:api_tokens), do: "Stride"
  def page_title(:edit_task), do: "Edit Task"
  def page_title(:edit_task_in_column), do: "Edit Task"
  def page_title(:manage_members), do: "Manage Members"
  def page_title(:board_settings), do: "Board Settings"

  def load_tasks_for_columns(socket, columns) do
    grouped = Tasks.list_tasks_by_columns(columns)

    tasks_by_column =
      Enum.into(columns, %{}, fn column ->
        tasks = grouped |> Map.get(column.id, []) |> sort_column_tasks(column)
        {column.id, tasks}
      end)

    goal_progress = Goals.compute_goal_progress(tasks_by_column, socket.assigns.board.id)
    backlog_goals_with_children = Goals.compute_backlog_promotable_goals(columns, tasks_by_column)
    goals_by_id = Goals.compute_goals_by_id(tasks_by_column)

    goals =
      Goals.compute_active_goals(
        tasks_by_column,
        columns,
        goals_by_id,
        backlog_goals_with_children
      )

    socket
    |> assign(:tasks_by_column, tasks_by_column)
    |> assign(:goal_progress, goal_progress)
    |> assign(:backlog_goals_with_children, backlog_goals_with_children)
    |> assign(:goals_by_id, goals_by_id)
    |> assign(:goals, goals)
    |> assign(:tasks_version, :os.system_time(:millisecond))
  end

  @goal_hierarchy_columns ~w(Backlog Ready Done)

  defp sort_column_tasks(tasks, %{name: name}) when name in @goal_hierarchy_columns,
    do: Tasks.sort_by_goal_hierarchy(tasks)

  defp sort_column_tasks(tasks, _column), do: tasks

  @doc """
  Returns true when the column is rendered using the goal-hierarchy sort
  (`sort_by_goal_hierarchy/1`), which groups each goal with its children and
  cannot be reproduced by ordering DOM elements by raw `data-position`. The
  client-side Sortable hook needs this signal so it skips its position-based
  resort and leaves the server-rendered order intact.
  """
  def goal_hierarchy_column?(%{name: name}) when name in @goal_hierarchy_columns, do: true
  def goal_hierarchy_column?(_), do: false

  def reload_board_data(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  # Re-reads the metrics for the currently-loaded board and reassigns
  # `:board` so the BoardHeader KV counts stay in sync after every
  # task move / create / delete / status change.
  def refresh_board_metrics(socket) do
    user = socket.assigns.current_scope.user
    board = put_board_metrics(socket.assigns.board, user)
    assign(socket, :board, board)
  end

  def refresh_board_tasks(socket, board) do
    columns = Columns.list_columns(board)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)
     |> load_tasks_for_columns(columns)}
  end
end
