defmodule KanbanWeb.GoalLive.Show do
  @moduledoc """
  Per-goal view page rendered at `/boards/:id/goals/:goal_id`. Scaffold
  introduced in W551 — body composition (header / child tree / metadata
  panel / activity log) is wired up in W552.

  Mounts inside the `:require_authenticated_user` live_session, looks
  the board up scope-aware via `Kanban.Boards.get_board/2`, then loads
  the goal via `Kanban.Tasks.get_task_for_view/1` while verifying the
  goal belongs to that board and is of type `:goal`. Unauthorized or
  type-mismatched access redirects back to `/boards` with a flash —
  matching the contract that `BoardLive.Show.handle_board_not_found/1`
  uses for every other scope-protected board route.
  """
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks

  @impl true
  def mount(%{"id" => board_id, "goal_id" => goal_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, board} <- Boards.get_board(board_id, user),
         {:ok, goal} <- fetch_goal(goal_id, board.id) do
      {:ok, assign_goal_view(socket, board, goal)}
    else
      _ -> {:ok, redirect_not_found(socket)}
    end
  end

  defp assign_goal_view(socket, board, goal) do
    socket
    |> assign(:board, board)
    |> assign(:goal, goal)
    |> assign(:page_title, page_title(goal))
  end

  defp redirect_not_found(socket) do
    socket
    |> put_flash(:error, gettext("Goal not found"))
    |> push_navigate(to: ~p"/boards")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} board={@board}>
      <:breadcrumbs>
        <.link navigate={~p"/boards"} style="color: var(--ink-3); text-decoration: none;">
          {gettext("Workspace")}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <.link navigate={~p"/boards"} style="color: var(--ink-3); text-decoration: none;">
          {gettext("Boards")}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <.link
          navigate={~p"/boards/#{@board}"}
          style="color: var(--ink-3); text-decoration: none;"
        >
          {@board.name}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <span class="ident" style="color: var(--ink); font-weight: 500;">
          {@goal.identifier}
        </span>
      </:breadcrumbs>

      <:actions>
        <.link navigate={~p"/boards/#{@board}"} class="btn btn-xs btn-ghost">
          {gettext("Back to board")}
        </.link>
      </:actions>

      <div data-goal-show class="stride-screen" style="padding: 14px 22px;">
        <h1 style="margin: 0; font-size: 18px; font-weight: 600; color: var(--ink);">
          {@goal.title}
        </h1>
        <p style="margin: 6px 0 0; font-size: 12px; color: var(--ink-3);">
          {gettext("Goal view scaffold — body composition lands in W552.")}
        </p>
      </div>
    </Layouts.app>
    """
  end

  # --- Private -----------------------------------------------------------

  defp fetch_goal(goal_id, board_id) do
    case parse_id(goal_id) do
      {:ok, id} ->
        case Tasks.get_task_for_view(id) do
          %{type: :goal, column: %{board_id: ^board_id}} = goal -> {:ok, goal}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp page_title(%{identifier: id, title: title}) when is_binary(id) and is_binary(title),
    do: "#{id} · #{title}"

  defp page_title(_), do: gettext("Goal")
end
