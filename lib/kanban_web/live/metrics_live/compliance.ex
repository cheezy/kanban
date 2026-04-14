defmodule KanbanWeb.MetricsLive.Compliance do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks.Compliance

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => board_id}, _url, socket) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        {:noreply, load_compliance(socket, board)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Board not found"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  defp load_compliance(socket, board) do
    user_id = socket.assigns.current_scope.user.id

    socket
    |> assign(:page_title, gettext("Compliance Metrics"))
    |> assign(:board, board)
    |> assign(:user_access, Boards.get_user_access(board.id, user_id))
    |> assign(:dispatch_rates, Compliance.step_dispatch_rates(board.id))
    |> assign(:skip_reasons, Compliance.skip_reasons(board.id))
    |> assign(:agent_compliance, Compliance.compliance_by_agent(board.id))
  end
end
