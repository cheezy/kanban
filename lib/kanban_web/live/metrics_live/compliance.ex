defmodule KanbanWeb.MetricsLive.Compliance do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks.Compliance
  alias KanbanWeb.TaskTokens

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => board_id}, _url, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, board} <- Boards.get_board(board_id, user),
         true <- Boards.can_modify?(board, user) do
      {:noreply, load_compliance(socket, board)}
    else
      {:error, :not_found} -> {:noreply, redirect_board_not_found(socket)}
      false -> {:noreply, redirect_compliance_forbidden(socket, board_id)}
    end
  end

  defp redirect_board_not_found(socket) do
    socket
    |> put_flash(:error, gettext("Board not found"))
    |> push_navigate(to: ~p"/boards")
  end

  defp redirect_compliance_forbidden(socket, board_id) do
    socket
    |> put_flash(
      :error,
      gettext("You don't have permission to view compliance metrics for this board.")
    )
    |> push_navigate(to: ~p"/boards/#{board_id}")
  end

  # W590: dispatch_rate_color/1 now returns a CSS color value
  # (consumed via inline `background: ...`) instead of a daisyUI class.
  defp dispatch_rate_color(rate) when rate >= 80.0, do: "var(--st-done)"
  defp dispatch_rate_color(rate) when rate >= 50.0, do: "var(--st-review)"
  defp dispatch_rate_color(_rate), do: "var(--st-blocked)"

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
