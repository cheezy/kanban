defmodule KanbanWeb.API.Me.BoardController do
  @moduledoc """
  The app's Boards tab (W2759, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.9, §7.10):

    * `GET /api/me/boards` lists every board the person can see, as `/boards`
      loads them, with its workspace group, per-column counts and idle agents
      (`Kanban.Boards.list_boards_for_app/2`);
    * `GET /api/me/boards/:id/columns/:name` returns one column's cards by
      position, 100 per page (`?page=`, 1-based), from
      `Kanban.Tasks.list_column_page/3`;
    * `POST /api/me/boards/:id/promote` moves several Backlog tasks to Ready in
      one transaction, setting `needs_review` when asked
      (`Kanban.Tasks.promote_to_ready/4`).

  It runs behind the `:device_api` pipeline, so `:current_scope` comes from
  `KanbanWeb.Plugs.AuthenticateDeviceToken`. Every route is plan-gated with
  `:mobile_app` (design §10): the person's plan first. The list then leaves out
  any board outside the plan; the column read and the promote check the
  board's plan once the person is known to see the board, so a
  `plan_required` answer never reveals a board they cannot see.

  A board is found as the web finds it (`Kanban.Boards.get_board/2`): a board
  the person holds no access to, or an id that is not one, answers 404. The
  column name is matched against the board's own columns
  (`Kanban.Columns.get_column_by_name/2`, the leftmost of that name, the
  column the board list counts), never put into a query, and an unknown one
  answers 404. A promote needs owner or modify access: a
  read-only member gets 403 `Forbidden` before the body is looked at.

  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Plans
  alias Kanban.Tasks
  alias KanbanWeb.API.Me.PageParams
  alias KanbanWeb.API.Me.PromoteParams
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  @write_access [:owner, :modify]

  def index(conn, _params) do
    %{current_scope: scope} = conn.assigns

    with :ok <- check_user(scope) do
      render(conn, :index, boards: Boards.list_boards_for_app(scope))
    end
  end

  def column(conn, %{"id" => id, "name" => name} = params) do
    %{current_scope: scope} = conn.assigns

    with {:ok, page} <- user_then_page(scope, params),
         {:ok, board} <- board_for(scope, id, :read),
         {:ok, assigns} <- read_column(scope, board, name, page) do
      render(conn, :column, assigns)
    end
  end

  def promote(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, board} <- board_for(scope, id, :write),
         {:ok, result} <- promote_body(conn, board) do
      render(conn, :promoted, result: result)
    end
  end

  # A board the person holds access to; a public board they are not a member
  # of is not one of their boards here, as it is not on /boards.
  defp fetch_board(scope, id) do
    with {:ok, board_id} <- parse_id(id),
         {:ok, %{user_access: access} = board} when not is_nil(access) <-
           Boards.get_board(board_id, scope.user) do
      {:ok, board}
    else
      _not_found -> {:error, :not_found}
    end
  end

  # The board, then the access the action needs, then the board's plan, in
  # that order, so plan_required never confirms a board the person cannot see.
  defp board_for(scope, id, need) do
    with {:ok, board} <- fetch_board(scope, id),
         :ok <- require_access(board, need),
         :ok <- Plans.check_board(board, :mobile_app, surface: :controller) do
      {:ok, board}
    end
  end

  defp require_access(_board, :read), do: :ok
  defp require_access(%{user_access: access}, :write) when access in @write_access, do: :ok
  defp require_access(_board, :write), do: {:error, :forbidden}

  defp check_user(scope), do: Plans.check_user(scope, :mobile_app, surface: :controller)

  # The person's plan, then the page, in the documented check order.
  defp user_then_page(scope, params) do
    with :ok <- check_user(scope), do: PageParams.parse(params)
  end

  # The column and its page, as the view's assigns.
  defp read_column(scope, board, name, page) do
    with {:ok, column} <- fetch_column(board, name),
         {:ok, column_page} <- Tasks.list_column_page(scope, column, page: page) do
      {:ok, board_id: board.id, column: column, page: column_page}
    end
  end

  # Only task_ids and needs_review are read from the body. A promotion is a
  # person's move into Ready, counted as the first action on the board's
  # empty Ready column when it fills it (Kanban.Decisions.acted_on/3).
  defp promote_body(conn, board) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with {:ok, task_ids, needs_review} <- PromoteParams.cast(conn.body_params) do
      act = [
        action: :move,
        via: device.platform,
        board_id: board.id,
        task_ids: task_ids,
        into_ready: true
      ]

      Decisions.acted_on(scope, act, fn ->
        Tasks.promote_to_ready(scope, board, task_ids, needs_review: needs_review)
      end)
    end
  end

  defp fetch_column(board, name) do
    case Columns.get_column_by_name(board.id, name) do
      nil -> {:error, :not_found}
      column -> {:ok, column}
    end
  end

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, board_id} -> {:ok, board_id}
      :error -> {:error, :not_found}
    end
  end
end
