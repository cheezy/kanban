defmodule KanbanWeb.TaskLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    user = socket.assigns.current_scope.user
    task = Tasks.get_task_for_view!(id)
    board = Boards.get_board!(task.column.board_id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    {:noreply,
     socket
     |> assign(:page_title, "Task #{task.identifier}")
     |> assign(:task, task)
     |> assign(:board, board)
     |> assign(:user_access, user_access)}
  end

  defp format_priority(priority) do
    case priority do
      :low -> gettext("Low")
      :medium -> gettext("Medium")
      :high -> gettext("High")
      :critical -> gettext("Critical")
      _ -> priority
    end
  end

  defp format_type(type) do
    case type do
      :work -> gettext("Work")
      :defect -> gettext("Defect")
      _ -> type
    end
  end

  defp priority_color(priority) do
    case priority do
      :low -> "text-blue-600"
      :medium -> "text-yellow-600"
      :high -> "text-orange-600"
      :critical -> "text-red-600"
      _ -> "text-gray-600"
    end
  end

  defp type_badge_color(type) do
    case type do
      :work -> "bg-blue-100 text-blue-800"
      :defect -> "bg-red-100 text-red-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp format_history_type(type) do
    case type do
      :creation -> gettext("Created")
      :move -> gettext("Moved")
      _ -> type
    end
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y at %I:%M %p")
  end
end
