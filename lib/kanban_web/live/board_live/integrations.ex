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

  It also says when the view has been opened anew (D480). `:integrations_opening`
  on the page is `nil` while another view is shown and `{board id, ref}` while
  this one is, with a new ref each time it is opened. The component forgets the
  one-time secret when that value changes, so what it shows never depends on
  when the browser reports the old view gone.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, push_patch: 2]

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

  @doc """
  Starts following the page's URL so every opening of the view is told apart.

  A `:handle_params` hook, because it runs for every URL of the page, including
  ones like `/boards/:id/integrations?task_id=1` that other `handle_params`
  clauses handle.
  """
  def track_openings(socket) do
    socket
    |> assign(:integrations_opening, nil)
    |> attach_hook(:integrations_opening, :handle_params, &track_opening/3)
  end

  @doc """
  Gives each opening of the view its own `:integrations_opening`.

  A patch that stays on the open view keeps it. Opening the view from another
  view, or on another board, makes a new one.
  """
  def track_opening(%{"id" => id}, _uri, %{assigns: %{live_action: :integrations}} = socket) do
    case socket.assigns.integrations_opening do
      {^id, _ref} -> {:cont, socket}
      _other -> {:cont, assign(socket, :integrations_opening, {id, make_ref()})}
    end
  end

  def track_opening(_params, _uri, socket) do
    {:cont, assign(socket, :integrations_opening, nil)}
  end

  @doc """
  Ends the current opening when the viewer stops being the owner.

  The page then hides the view without a URL change, and shows it again if the
  viewer becomes the owner again: that is a new opening too.
  """
  def end_opening(%{assigns: %{integrations_opening: {id, _ref}}} = socket),
    do: assign(socket, :integrations_opening, {id, make_ref()})

  def end_opening(socket), do: socket
end
