defmodule KanbanWeb.BoardLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias KanbanWeb.BoardPulseCard

  attr :access, :atom, required: true

  defp access_badge(%{access: :owner} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold"
      style="background: var(--st-doing-soft); color: var(--st-doing); border: 1px solid var(--line);"
      title={gettext("Owner")}
    >
      <.icon name="hero-star-solid" class="h-3 w-3" />
      <span>{gettext("Owner")}</span>
    </span>
    """
  end

  defp access_badge(%{access: :modify} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold"
      style="background: var(--st-ready-soft); color: var(--st-ready); border: 1px solid var(--line);"
      title={gettext("Can Edit")}
    >
      <.icon name="hero-pencil-solid" class="h-3 w-3" />
      <span>{gettext("Can Edit")}</span>
    </span>
    """
  end

  defp access_badge(%{access: :read_only} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold"
      style="background: var(--surface-2); color: var(--ink-3); border: 1px solid var(--line);"
      title={gettext("Read Only")}
    >
      <.icon name="hero-eye-solid" class="h-3 w-3" />
      <span>{gettext("Read Only")}</span>
    </span>
    """
  end

  defp access_badge(assigns), do: ~H""

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
        <.link navigate={~p"/boards/new"}>
          <.button class="w-full btn-sm btn-outline gap-2">
            <.icon name="hero-document" class="h-4 w-4" />
            <span class="text-xs">{gettext("Empty Board")}</span>
          </.button>
        </.link>
        <.link navigate={~p"/boards/new?ai_optimized=true"}>
          <.button class="w-full btn-sm gap-2">
            <.icon name="hero-sparkles" class="h-4 w-4" />
            <span class="text-xs">{gettext("AI Optimized")}</span>
          </.button>
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    boards = Boards.list_boards_with_metrics(user)

    {:ok,
     socket
     |> assign(:has_boards, not Enum.empty?(boards))
     |> assign(:active_count, length(boards))
     |> stream(:boards, boards)}
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
