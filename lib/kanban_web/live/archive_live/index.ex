defmodule KanbanWeb.ArchiveLive.Index do
  @moduledoc """
  Workspace Archive page at `/boards/:id/archive`.

  Replaces the legacy daisyUI table with the W570-W576 composition:
  `ArchiveStatsStrip` + `ArchiveFilterChips` + month-grouped `ArchiveRow`
  rows + a read-only footer hint. All data reads route through
  `Kanban.Archives` per the project rule against Ecto in LiveViews.

  Filter changes re-derive `:rows` from `:all_rows` in memory rather
  than re-querying — mirrors the filter-tab pattern in
  `KanbanWeb.AgentsLive`.
  """
  use KanbanWeb, :live_view

  alias Kanban.Archives
  alias Kanban.Boards
  alias Kanban.Tasks

  require Logger

  @valid_reasons [:completed, :cancelled, :wontdo, :duplicate, :deferred]

  @impl true
  def mount(%{"id" => board_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        {:ok, assign_archive_state(socket, board, user)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Board not found"))
         |> push_navigate(to: ~p"/boards")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("filter_archive", %{"reason" => raw}, socket) do
    filter = parse_filter(raw)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:rows, apply_filter(socket.assigns.all_rows, filter))
     |> close_menu()}
  end

  @impl true
  def handle_event("open_archive_menu", %{"id" => id}, socket) do
    {:noreply, assign(socket, :menu_open_for, to_string(id))}
  end

  @impl true
  def handle_event("close_archive_menu", _params, socket) do
    {:noreply, close_menu(socket)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Export CSV — coming soon."))}
  end

  @impl true
  def handle_event("bulk_archive_old", _params, socket) do
    if socket.assigns.can_modify do
      perform_bulk_archive(socket)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You do not have permission to archive tasks on this board")
       )}
    end
  end

  @impl true
  def handle_event("unarchive", %{"id" => id}, socket) do
    socket
    |> authorize_modify_for_archived(id)
    |> case do
      {:ok, task} -> perform_unarchive(socket, task)
      {:error, reason} -> {:noreply, flash_for(socket, :unarchive, reason)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    socket
    |> authorize_modify_for_archived(id)
    |> case do
      {:ok, task} -> perform_delete(socket, task)
      {:error, reason} -> {:noreply, flash_for(socket, :delete, reason)}
    end
  end

  # --- PubSub --------------------------------------------------------------

  @impl true
  def handle_info({Kanban.Tasks, event, _task}, socket)
      when event in [:task_updated, :task_deleted] do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State ---------------------------------------------------------------

  defp assign_archive_state(socket, board, user) do
    user_access = Boards.get_user_access(board.id, user.id)
    subscribe_to_board_updates(socket, board.id)

    all_rows = load_rows(board.id)
    stats = load_stats(board.id)

    socket
    |> assign(:page_title, "Stride · Archive")
    |> assign(:board, board)
    |> assign(:user_access, user_access)
    |> assign(:can_modify, user_access in [:owner, :modify])
    |> assign(:is_owner, user_access == :owner)
    |> assign(:filter, :all)
    |> assign(:all_rows, all_rows)
    |> assign(:rows, all_rows)
    |> assign(:stats, stats)
    |> assign(:menu_open_for, nil)
  end

  defp reload(socket) do
    board_id = socket.assigns.board.id
    all_rows = load_rows(board_id)

    socket
    |> assign(:all_rows, all_rows)
    |> assign(:rows, apply_filter(all_rows, socket.assigns.filter))
    |> assign(:stats, load_stats(board_id))
    |> close_menu()
  end

  defp load_rows(board_id), do: Archives.list_archived_for_board(board_id)

  defp load_stats(board_id), do: Archives.archive_stats_for_board(board_id)

  defp apply_filter(rows, :all), do: rows

  defp apply_filter(rows, :completed) do
    Enum.filter(rows, fn task ->
      reason = task.archive_reason
      reason == :completed or is_nil(reason)
    end)
  end

  defp apply_filter(rows, reason) when reason in @valid_reasons do
    Enum.filter(rows, fn task -> task.archive_reason == reason end)
  end

  defp close_menu(socket), do: assign(socket, :menu_open_for, nil)

  defp parse_filter("all"), do: :all

  defp parse_filter(raw) when is_binary(raw) do
    case Enum.find(@valid_reasons, fn r -> Atom.to_string(r) == raw end) do
      nil ->
        Logger.warning("ArchiveLive: unknown filter reason #{inspect(raw)} — defaulting to :all")
        :all

      reason ->
        reason
    end
  end

  defp parse_filter(_), do: :all

  # --- Counts for the filter chips -----------------------------------------

  defp counts_for(all_rows) do
    base = %{all: length(all_rows)}

    @valid_reasons
    |> Enum.reduce(base, fn reason, acc ->
      count = Enum.count(all_rows, &reason_matches?(&1, reason))
      Map.put(acc, reason, count)
    end)
  end

  defp reason_matches?(%{archive_reason: nil}, :completed), do: true
  defp reason_matches?(%{archive_reason: r}, target), do: r == target

  # --- Month grouping for the table body -----------------------------------

  defp group_by_month(rows) do
    rows
    |> Enum.group_by(&month_key/1)
    |> Enum.sort_by(fn {key, _} -> sort_key(key) end)
    |> Enum.map(&build_month_group/1)
  end

  defp sort_key({year, month}), do: {-year, -month}

  defp build_month_group({{year, month}, group_rows}) do
    %{
      key: "#{year}-#{month}",
      label: month_label(year, month),
      count: length(group_rows),
      goal_groups: Tasks.group_rows_by_goal(group_rows)
    }
  end

  defp month_key(%{archived_at: %DateTime{year: year, month: month}}), do: {year, month}
  defp month_key(_), do: {0, 0}

  defp month_label(0, 0), do: gettext("Undated")

  defp month_label(year, month) do
    {:ok, date} = Date.new(year, month, 1)
    Calendar.strftime(date, "%B %Y")
  end

  # --- Mutations -----------------------------------------------------------

  defp perform_bulk_archive(socket) do
    board_id = socket.assigns.board.id
    {:ok, count} = Tasks.bulk_archive_completed_tasks_older_than(board_id)

    {:noreply,
     socket
     |> put_flash(:info, bulk_archive_flash(count))
     |> reload()}
  end

  defp bulk_archive_flash(0) do
    gettext("No completed tasks older than 30 days were found.")
  end

  defp bulk_archive_flash(1) do
    gettext("Archived 1 completed task older than 30 days.")
  end

  defp bulk_archive_flash(count) do
    gettext("Archived %{count} completed tasks older than 30 days.", count: count)
  end

  defp perform_unarchive(socket, task) do
    case Tasks.unarchive_task(task) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Task unarchived successfully"))
         |> reload()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to unarchive task"))}
    end
  end

  defp perform_delete(socket, task) do
    case Tasks.delete_task(task) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted successfully"))
         |> reload()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  defp flash_for(socket, :unarchive, :not_authorized) do
    put_flash(
      socket,
      :error,
      gettext("You do not have permission to unarchive tasks on this board")
    )
  end

  defp flash_for(socket, :delete, :not_authorized) do
    put_flash(
      socket,
      :error,
      gettext("You do not have permission to delete tasks on this board")
    )
  end

  defp flash_for(socket, :unarchive, _other) do
    put_flash(socket, :error, gettext("Failed to unarchive task"))
  end

  defp flash_for(socket, :delete, _other) do
    put_flash(socket, :error, gettext("Failed to delete task"))
  end

  # --- Lookup helpers ------------------------------------------------------

  defp authorize_modify_for_archived(socket, raw_id) do
    if socket.assigns.can_modify do
      lookup_archived_task(socket, raw_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_archived_task(socket, raw_id) do
    with {:ok, id} <- parse_id(raw_id),
         %{} = task <- Tasks.get_archived_task_for_board(id, socket.assigns.board.id) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end
end
