defmodule KanbanWeb.ArchiveLive.Index do
  @moduledoc """
  Workspace Archive page at `/boards/:id/archive`.

  Replaces the legacy daisyUI table with the W570-W576 composition:
  `ArchiveStatsStrip` + `ArchiveFilterChips` + a flat goal-grouped list of
  `ArchiveRow` rows (via `Kanban.Tasks.group_rows_by_goal/1`) + a read-only
  footer hint. All data reads route through `Kanban.Archives` per the
  project rule against Ecto in LiveViews.

  Filter changes re-derive `:rows` from `:all_rows` in memory rather
  than re-querying — mirrors the filter-tab pattern in
  `KanbanWeb.AgentsLive`.
  """
  use KanbanWeb, :live_view

  alias Kanban.Archives
  alias Kanban.Boards
  alias Kanban.Tasks

  require Logger

  @valid_reasons [:completed]

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
    {:noreply,
     socket
     |> assign(:filter, parse_filter(raw))
     |> recompute_rows()
     |> close_menu()}
  end

  @impl true
  def handle_event("toggle_assignee_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:assignee_menu_open, not socket.assigns.assignee_menu_open)
     |> close_menu()}
  end

  @impl true
  def handle_event("close_assignee_menu", _params, socket) do
    {:noreply, assign(socket, :assignee_menu_open, false)}
  end

  @impl true
  def handle_event("filter_assignee", %{"assignee" => raw}, socket) do
    {:noreply,
     socket
     |> assign(:assignee_filter, parse_assignee(raw))
     |> assign(:assignee_menu_open, false)
     |> recompute_rows()
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
  def handle_event("toggle_goal_group", %{"group_key" => key}, socket) when is_binary(key) do
    {:noreply,
     assign(
       socket,
       :collapsed_goal_groups,
       toggle_member(socket.assigns.collapsed_goal_groups, key)
     )}
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
    |> assign(:assignee_filter, :all)
    |> assign(:assignee_menu_open, false)
    |> assign(:all_rows, all_rows)
    |> assign(:rows, all_rows)
    |> assign(:stats, stats)
    |> assign(:menu_open_for, nil)
    |> assign(:collapsed_goal_groups, MapSet.new())
  end

  defp reload(socket) do
    board_id = socket.assigns.board.id
    all_rows = load_rows(board_id)

    socket
    |> assign(:all_rows, all_rows)
    |> recompute_rows()
    |> assign(:stats, load_stats(board_id))
    |> close_menu()
  end

  defp load_rows(board_id), do: Archives.list_archived_for_board(board_id)

  defp load_stats(board_id), do: Archives.archive_stats_for_board(board_id)

  # Re-derive the visible :rows from :all_rows by composing BOTH filter
  # dimensions (reason then assignee). Every event/reload that changes either
  # dimension or reloads the rows must route through here so neither filter
  # silently resets the other.
  defp recompute_rows(socket) do
    rows =
      socket.assigns.all_rows
      |> apply_reason_filter(socket.assigns.filter)
      |> apply_assignee_filter(socket.assigns.assignee_filter)

    assign(socket, :rows, rows)
  end

  defp apply_reason_filter(rows, :all), do: rows

  defp apply_reason_filter(rows, :completed) do
    Enum.filter(rows, fn task ->
      reason = task.archive_reason
      reason == :completed or is_nil(reason)
    end)
  end

  defp apply_assignee_filter(rows, :all), do: rows

  defp apply_assignee_filter(rows, :unassigned) do
    Enum.filter(rows, &is_nil(&1.assigned_to))
  end

  defp apply_assignee_filter(rows, id) when is_integer(id) do
    Enum.filter(rows, fn task -> match?(%{id: ^id}, task.assigned_to) end)
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

  # Coerce the assignee chip's phx-value into the :assignee_filter model.
  # Never String.to_atom the inbound value: parse ids with Integer.parse and
  # string-compare the 'all'/'unassigned' sentinels. Anything unparseable
  # degrades to :all (clear the filter) without crashing.
  defp parse_assignee("all"), do: :all
  defp parse_assignee("unassigned"), do: :unassigned

  defp parse_assignee(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> :all
    end
  end

  defp parse_assignee(_), do: :all

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

  # --- Assignees for the filter dropdown -----------------------------------

  # Derive the distinct present assignees from the already-loaded, board-scoped
  # @all_rows — no Ecto query in the LiveView (AGENTS.md). Returns plain
  # %{id, name} maps sorted by name so the dropdown order is deterministic. The
  # match?/2 filter drops both nil and any (defensively) unloaded association.
  defp assignees_for(all_rows) do
    all_rows
    |> Enum.map(& &1.assigned_to)
    |> Enum.filter(&match?(%{id: _}, &1))
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn user -> %{id: user.id, name: assignee_name(user)} end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp has_unassigned?(all_rows), do: Enum.any?(all_rows, &is_nil(&1.assigned_to))

  # Mirrors ArchiveRow.user_name/1: name -> email -> "?".
  defp assignee_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp assignee_name(%{email: email}) when is_binary(email), do: email
  defp assignee_name(_), do: "?"

  # --- Goal grouping for the table body ------------------------------------

  # The archive renders one flat list of goal groups (each goal's own row with
  # its chevron and nested children) plus the "Tasks Without Goals" group — no
  # month sections. Keys are the plain group_rows_by_goal/1 keys
  # ("goal:<id>" / "no_goal").
  defp goal_groups(rows), do: Tasks.group_rows_by_goal(rows)

  # A goal group renders expanded unless the user has collapsed it. Tracking
  # collapsed keys (rather than expanded ones) means the default — empty set —
  # is "all expanded", and keys that vanish after a filter/reload are simply
  # ignored instead of needing recomputation.
  defp group_expanded?(collapsed, key), do: not MapSet.member?(collapsed, key)

  # Flip a member's presence in a MapSet: drop it when present, add it when
  # absent. Backs the per-goal-group collapse state.
  defp toggle_member(set, member) do
    if MapSet.member?(set, member),
      do: MapSet.delete(set, member),
      else: MapSet.put(set, member)
  end

  # --- Row rendering -------------------------------------------------------

  # One archived row plus its kebab action-menu overlay. Passing the toggle_*
  # attrs makes the row's leading cell render a chevron (used for a goal's own
  # row); omitting them renders the row exactly as a plain archived row.
  attr :task, :map, required: true
  attr :menu_open_for, :string, default: nil
  attr :can_modify, :boolean, default: false
  attr :toggle_event, :string, default: nil
  attr :toggle_group_key, :string, default: nil
  attr :expanded, :boolean, default: true

  defp row_with_menu(assigns) do
    ~H"""
    <div data-archive-row-wrapper style="position: relative;">
      <KanbanWeb.ArchiveRow.archive_row
        task={@task}
        on_action_menu="open_archive_menu"
        toggle_event={@toggle_event}
        toggle_group_key={@toggle_group_key}
        expanded={@expanded}
      />

      <div
        :if={@menu_open_for == to_string(@task.id)}
        data-archive-row-menu
        phx-click-away="close_archive_menu"
        style={[
          "position: absolute; right: 14px; top: 32px; z-index: 10;",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 6px;",
          "box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);",
          "display: flex; flex-direction: column;",
          "min-width: 160px;"
        ]}
      >
        <button
          :if={@can_modify}
          type="button"
          data-archive-menu-restore
          phx-click="unarchive"
          phx-value-id={@task.id}
          style={[
            "padding: 8px 12px; border: 0; background: transparent;",
            "text-align: left; font: inherit; font-size: 12px;",
            "color: var(--ink); cursor: pointer;"
          ]}
        >
          {gettext("Restore")}
        </button>

        <button
          :if={@can_modify}
          type="button"
          data-archive-menu-delete
          phx-click="delete"
          phx-value-id={@task.id}
          data-confirm={gettext("Are you sure you want to delete this task?")}
          style={[
            "padding: 8px 12px; border: 0; background: transparent;",
            "text-align: left; font: inherit; font-size: 12px;",
            "color: var(--st-blocked); cursor: pointer;",
            "border-top: 1px solid var(--line);"
          ]}
        >
          {gettext("Delete forever")}
        </button>

        <span
          :if={not @can_modify}
          data-archive-menu-read-only
          style="padding: 8px 12px; font-size: 11.5px; color: var(--ink-3); font-style: italic;"
        >
          {gettext("Read-only access")}
        </span>
      </div>
    </div>
    """
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
