defmodule KanbanWeb.BoardLive.BoardGroups do
  @moduledoc """
  Function components for the `/boards` grid (`KanbanWeb.BoardLive.Index`).

  `board_card/1` is one board's card with the owner's edit and delete controls.
  `board_section/1` is a headed group of cards, used when the user has a
  current workspace and the page splits into the workspace's boards, Personal
  boards and other shared boards (`Kanban.Workspaces.Current.group_boards/2`).
  """
  use KanbanWeb, :html

  alias KanbanWeb.BoardPulseCard

  @doc """
  Renders one board card. `id` is the stream's DOM id, which the delete control
  hides optimistically.
  """
  attr :id, :string, required: true
  attr :board, :map, required: true

  def board_card(assigns) do
    ~H"""
    <div id={@id} class="relative group h-full">
      <BoardPulseCard.board_pulse_card board={@board} />

      <div class="absolute top-2 right-2 flex items-center gap-1">
        <.link
          :if={Map.get(@board, :user_access) == :owner}
          navigate={~p"/boards/#{@board}/edit"}
          class="inline-flex items-center justify-center min-h-11 min-w-11 md:min-h-0 md:min-w-0 opacity-100 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100 transition-opacity p-1 rounded hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          aria-label={gettext("Edit board")}
        >
          <.icon name="hero-pencil-square" class="h-4 w-4" />
        </.link>
        <.link
          :if={Map.get(@board, :user_access) == :owner}
          phx-click={JS.push("delete", value: %{id: @board.id}) |> hide("##{@id}")}
          data-confirm={gettext("Are you sure you want to delete this board?")}
          class="inline-flex items-center justify-center min-h-11 min-w-11 md:min-h-0 md:min-w-0 opacity-100 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100 transition-opacity p-1 rounded hover:bg-[var(--st-blocked-soft)] text-[var(--st-blocked)] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          aria-label={gettext("Delete board")}
        >
          <.icon name="hero-trash" class="h-4 w-4" />
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Renders a headed group of board cards from a stream, with `empty` shown when
  the group has no boards.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :stream, :any, required: true
  attr :empty, :string, required: true

  def board_section(assigns) do
    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-title"} class="mb-8">
      <div class="flex items-baseline gap-2 mb-3">
        <h2
          id={"#{@id}-title"}
          style="margin: 0; font-size: 14px; font-weight: 600; color: var(--ink); overflow-wrap: anywhere;"
        >
          {@title}
        </h2>
        <span class="ident" style="color: var(--ink-3);">{@count}</span>
      </div>
      <p
        :if={@count == 0}
        style="margin: 0; font-size: 12.5px; color: var(--ink-2);"
      >
        {@empty}
      </p>
      <div :if={@count > 0} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div id={"#{@id}-grid"} phx-update="stream" class="contents">
          <.board_card :for={{dom_id, board} <- @stream} id={dom_id} board={board} />
        </div>
      </div>
    </section>
    """
  end
end
