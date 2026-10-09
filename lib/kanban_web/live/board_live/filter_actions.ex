defmodule KanbanWeb.BoardLive.FilterActions do
  @moduledoc """
  Socket-level handling of the board filter bar for `KanbanWeb.BoardLive.Show`
  (W2235), kept out of the LiveView to hold it under the module-size
  guideline.

  The URL is the source of truth: `filter_change` and `clear_filters` only
  `push_patch` a new query string, and `assign_filters/3` — called from
  `handle_params` — turns that query string back into `:board_filters`. So a
  filtered board URL can be shared, survives a reload, and the browser's
  back button steps through filter changes.

  The selector options (the board's labels and members) are cached per board
  in `:filter_options`; their ids are also the whitelist
  `KanbanWeb.BoardLive.FilterParams.restrict/3` applies to the URL. The cache
  is reloaded when a URL names a label or assignee it does not hold, so a
  label created or a member added since the board opened still filters.
  """
  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2, put_flash: 3]

  alias Kanban.Boards
  alias Kanban.Labels
  alias Kanban.Tasks.BoardFilters
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.FilterParams

  @doc "The `:filter_options` assign before any board is loaded."
  def empty_options, do: %{board_id: nil, labels: [], members: []}

  @doc """
  Parses the board URL's query params into `:board_filters`, restricted to
  the board's own members and labels, loading the selector options first
  when they are not cached for this board. Returns `{socket, changed?}`,
  where `changed?` says whether the filters differ from the previous ones.
  """
  def assign_filters(socket, board, params) do
    parsed = FilterParams.parse(params)
    socket = ensure_options(socket, board, parsed)
    previous = socket.assigns[:board_filters]
    filters = restrict(parsed, socket.assigns.filter_options)

    {assign(socket, :board_filters, filters), filters != previous}
  end

  @doc """
  Handles the filter bar's `phx-change`/`phx-submit`: patches the URL to the
  new filters, or does nothing when they did not change.
  """
  def handle_filter_change(socket, params) do
    filters = params |> FilterParams.parse() |> restrict(socket.assigns.filter_options)

    if filters == socket.assigns[:board_filters] do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: board_path(socket.assigns.board, filters))}
    end
  end

  @doc "Handles the Clear action: patches back to the unfiltered board URL."
  def clear_filters(socket) do
    {:noreply, push_patch(socket, to: ~p"/boards/#{socket.assigns.board}")}
  end

  @doc """
  Rejects a drag-and-drop move made while filters are active. A filtered
  column's positions do not match the real column order, so applying the
  move would corrupt it. Re-renders the columns so the card snaps back.
  """
  def reject_filtered_move(socket) do
    socket
    |> put_flash(:error, gettext("Clear the filters to reorder cards"))
    |> push_event("move_failed", %{})
    |> BoardState.reload_board_data()
  end

  @doc "The board URL carrying `filters` as query params."
  def board_path(board, %BoardFilters{} = filters) do
    case FilterParams.encode(filters) do
      [] -> ~p"/boards/#{board}"
      query -> ~p"/boards/#{board}?#{query}"
    end
  end

  defp restrict(filters, %{labels: labels, members: members}) do
    FilterParams.restrict(filters, member_ids(members), Enum.map(labels, & &1.id))
  end

  defp member_ids(members), do: Enum.map(members, & &1.user_id)

  defp ensure_options(socket, board, parsed) do
    options = socket.assigns[:filter_options]

    if cached?(options, board, parsed) do
      socket
    else
      reload_options(socket, board)
    end
  end

  @doc """
  Reloads the cached selector options for `board`. Called when the board's
  labels change (W2233), so the filter bar never offers a deleted label or
  misses a new or renamed one.
  """
  def reload_options(socket, board) do
    assign(socket, :filter_options, %{
      board_id: board.id,
      labels: Labels.list_viewable_labels(socket.assigns.current_scope, board),
      members: Boards.list_board_members(board.id)
    })
  end

  # The cache serves this board and already holds every id the URL names.
  defp cached?(%{board_id: board_id} = options, %{id: board_id}, parsed) do
    known?(parsed.label_id, Enum.map(options.labels, & &1.id)) and
      known?(parsed.assignee, member_ids(options.members))
  end

  defp cached?(_options, _board, _parsed), do: false

  defp known?(id, ids) when is_integer(id), do: id in ids
  defp known?(_id, _ids), do: true
end
