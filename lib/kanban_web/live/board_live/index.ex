defmodule KanbanWeb.BoardLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias KanbanWeb.BoardPulseCard

  defp empty_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center px-4" style="min-height: 60vh;">
      <div
        class="w-full grid gap-8 md:gap-12 items-center grid-cols-1 md:grid-cols-[1fr_auto]"
        style="max-width: 880px;"
      >
        <div
          class="flex flex-col items-start gap-4 text-left"
          style="max-width: 520px;"
        >
          <h1
            class="text-[26px] md:text-[30px]"
            style={[
              "margin: 0; font-weight: 600;",
              "letter-spacing: -0.025em; line-height: 1.15; color: var(--ink);",
              "text-wrap: balance;"
            ]}
          >
            {gettext("No boards yet.")}<br />{gettext("Let's start with one.")}
          </h1>
          <p style="margin: 0; font-size: 14.5px; line-height: 1.55; color: var(--ink-2); text-wrap: pretty;">
            {gettext(
              "A board is a workspace for a single product or codebase. Stride gives you the 5-column AI flow out of the box — your agents pull from Ready, humans approve in Review. You can change the columns later."
            )}
          </p>
          <div
            class="flex flex-col sm:flex-row sm:items-center gap-2 w-full sm:w-auto"
            style="margin-top: 6px;"
          >
            <.link navigate={~p"/boards/new"} class="w-full sm:w-auto">
              <.button class="btn-primary btn-sm gap-2 w-full sm:w-auto">
                <.icon name="hero-plus" class="h-4 w-4" />
                {gettext("Create your first board")}
              </.button>
            </.link>
            <button
              type="button"
              disabled
              title={gettext("Coming soon")}
              class="btn btn-sm btn-outline gap-2 w-full sm:w-auto"
              style="cursor: not-allowed; opacity: 0.6;"
            >
              <.icon name="hero-link" class="h-4 w-4" />
              {gettext("Import from Linear or Jira")}
            </button>
          </div>
          <p
            class="ident"
            style="margin: 8px 0 0; font-size: 11.5px; color: var(--ink-3);"
          >
            {gettext(
              "Tip: start with the board your team already works in. Stride can backfill history."
            )}
          </p>
        </div>

        <div class="hidden md:flex md:justify-center">
          <.boards_empty_diagram />
        </div>
      </div>
    </div>
    """
  end

  defp boards_empty_diagram(assigns) do
    ~H"""
    <div
      aria-hidden="true"
      style={[
        "width: 320px; height: 220px; padding: 14px;",
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 12px; box-shadow: var(--shadow-md);",
        "display: flex; flex-direction: column; gap: 10px;"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px;">
        <span style="width: 26px; height: 26px; border-radius: 6px; background: var(--line);"></span>
        <span style="flex: 1; height: 10px; border-radius: 3px; background: var(--surface-sunken);">
        </span>
      </div>
      <span style="height: 8px; border-radius: 3px; background: var(--surface-sunken); width: 60%;">
      </span>
      <div style="height: 36px; background: var(--surface-sunken); border-radius: 6px; margin-top: 6px;">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 4px; margin-top: 6px;">
        <div :for={_ <- 1..4} style="display: flex; flex-direction: column; gap: 4px;">
          <span style="height: 6px; background: var(--surface-sunken); border-radius: 2px; width: 60%;">
          </span>
          <span style="height: 14px; background: var(--line); border-radius: 3px; width: 50%;"></span>
        </div>
      </div>
      <div style="display: flex; gap: 4px; margin-top: auto;">
        <span style="width: 16px; height: 16px; border-radius: 8px; background: var(--line);"></span>
        <span style="width: 16px; height: 16px; border-radius: 8px; background: var(--line); margin-left: -6px;">
        </span>
        <span style="width: 16px; height: 16px; border-radius: 8px; background: var(--line); margin-left: -6px;">
        </span>
      </div>
    </div>
    """
  end

  defp new_board_affordance(assigns) do
    ~H"""
    <div
      role="region"
      aria-label={gettext("Create new board")}
      style={[
        "border: 1.5px dashed var(--line-strong); border-radius: 8px;",
        "padding: 14px 14px 12px; background: transparent;",
        "min-height: 220px; display: flex; flex-direction: column;",
        "align-items: center; justify-content: center; gap: 10px;",
        "color: var(--ink-3);"
      ]}
    >
      <.icon name="hero-plus-circle" class="h-8 w-8" />
      <p style="margin: 0; font-size: 12px; font-weight: 600; color: var(--ink-2);">
        {gettext("New board")}
      </p>
      <div class="flex flex-col gap-2 w-full max-w-[12rem]">
        <.link
          navigate={~p"/boards/new"}
          class="inline-flex items-center justify-center gap-1.5 cursor-pointer"
          style={[
            "padding: 6px 10px; border-radius: 5px;",
            "background: transparent; color: var(--ink-2);",
            "border: 1px solid var(--line-strong);",
            "font-size: 12px; font-weight: 500;"
          ]}
        >
          <.icon name="hero-document" class="h-3.5 w-3.5" />
          <span>{gettext("Empty Board")}</span>
        </.link>
        <.link
          navigate={~p"/boards/new?ai_optimized=true"}
          class="inline-flex items-center justify-center gap-1.5 cursor-pointer"
          style={[
            "padding: 6px 10px; border-radius: 5px;",
            "background: var(--ink); color: white; border: none;",
            "font-size: 12px; font-weight: 500;",
            "box-shadow: 0 1px 0 rgba(255,255,255,.1) inset, 0 1px 2px rgba(0,0,0,.2);"
          ]}
        >
          <.icon name="hero-sparkles" class="h-3.5 w-3.5" />
          <span>{gettext("AI Optimized")}</span>
        </.link>
      </div>
    </div>
    """
  end

  @accents ~w(orange violet doing ready backlog blocked)a

  @impl true
  def mount(_params, _session, socket) do
    boards = load_boards(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:has_boards, not Enum.empty?(boards))
     |> assign(:active_count, length(boards))
     |> assign(:nav_active, :boards)
     |> stream(:boards, boards)}
  end

  defp load_boards(user) do
    user
    |> Boards.list_boards_with_metrics()
    |> Enum.with_index()
    |> Enum.map(fn {board, index} ->
      Map.put(board, :accent, Enum.at(@accents, rem(index, length(@accents))))
    end)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Stride")}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(id, user) do
      {:ok, board} -> attempt_board_deletion(socket, board, user)
      {:error, :not_found} -> board_not_found_response(socket)
    end
  end

  defp attempt_board_deletion(socket, board, user) do
    case Boards.delete_board(board, user) do
      {:ok, _} ->
        boards = Boards.list_boards_with_metrics(user)

        {:noreply,
         socket
         |> assign(:has_boards, not Enum.empty?(boards))
         |> assign(:active_count, length(boards))
         |> stream_delete(:boards, board)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Only the board owner can delete this board"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  defp board_not_found_response(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Board not found"))
     |> push_navigate(to: ~p"/boards")}
  end
end
