defmodule KanbanWeb.BoardLive.Integrations do
  @moduledoc """
  Route gate for the board's Integrations view (`/boards/:id/integrations`,
  W2228), in the style of `KanbanWeb.BoardLive.ApiTokens`.

  Only the board's owner gets the view; anyone else is sent back to the
  board with a flash. This is the route gate only: the endpoints, the
  one-time secret and the delivery log live in
  `KanbanWeb.BoardLive.IntegrationsComponent`, which re-checks ownership
  on every event that names an endpoint or writes one (see its moduledoc).
  Integrations work on every board, AI-optimized or not.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  alias Kanban.Columns
  alias KanbanWeb.BoardLive.BoardState

  @doc "Assigns the board state for the owner; redirects anyone else to the board."
  def resolve_integrations_view(socket, board, :owner) do
    {:noreply,
     socket
     |> BoardState.assign_common_board_state(board, :owner, Columns.list_columns(board))
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)}
  end

  def resolve_integrations_view(socket, board, _user_access) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Only the board owner can manage integrations"))
     |> push_patch(to: ~p"/boards/#{board}")}
  end
end
