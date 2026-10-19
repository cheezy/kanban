defmodule KanbanWeb.BoardLive.BulkSelection do
  @moduledoc """
  Selection mode and bulk actions for `KanbanWeb.BoardLive.Show` (W2238),
  kept out of the LiveView to hold it under the module-size guideline. Show
  routes every `bulk_*` event here.

  The selection is server state: `:selected_ids` is a `MapSet` of task ids
  that only ever holds ids of cards currently visible on the board.
  `bulk_toggle` and `bulk_select_column` accept an id only when it is
  visible, and `prune/1` — called by `BoardState.load_tasks_for_columns/2` on
  every load, PubSub refresh and filter change — drops any id that has been
  deleted, archived, moved off the board or hidden by a filter. The actions
  always send that server-held selection to `Kanban.Tasks.BulkActions`,
  never ids from the event params, and BulkActions re-checks access and
  re-resolves every id against the board itself.

  Every event is refused unless the viewer can modify the board, so a forged
  event from a read-only member changes nothing. While paid plans are
  enforced, every event on a free board is then refused
  (`Kanban.Plans.check_board/3`, surface `:live_view`), and
  `Kanban.Tasks.BulkActions` refuses the actions again in the context.
  `assign_lock/2` sets `:bulk_locked?` once per board. On a locked board the
  Select toggle stays, but it opens and closes the locked prompt
  (`:bulk_prompt_open?`) in place of the bar, without a flash and without
  entering selection mode; every other event is refused with a flash and
  opens the prompt. An event the plan check allows clears the lock, so a
  board moved into an Organization unlocks on its next event. Cards render inside the
  `:columns` stream, so a selection change re-inserts the columns to
  re-render the checkboxes.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3, stream: 3]

  alias Kanban.Plans
  alias Kanban.Tasks
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.ColumnActions
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.BoardLive.Show

  @doc """
  Assigns an empty selection with selection mode off and the locked prompt
  closed, and bulk actions unlocked until `assign_lock/2` has seen a board.
  """
  def init(socket) do
    socket
    |> reset(false)
    |> assign(:bulk_prompt_open?, false)
    |> assign(:bulk_locked?, false)
    |> assign(:bulk_lock_board_id, nil)
  end

  @doc """
  Assigns `:bulk_locked?` for `board`: true while paid plans are enforced and
  the board is free. It is computed the first time this socket loads the
  board and kept on later patches and filter changes, so the plan is not
  re-read on every load. With enforcement off it never queries.
  """
  def assign_lock(%{assigns: %{bulk_lock_board_id: board_id}} = socket, %{id: board_id}),
    do: socket

  def assign_lock(socket, %{id: board_id}) do
    socket
    |> assign(:bulk_locked?, not Plans.board_unlocked?(board_id))
    |> assign(:bulk_lock_board_id, board_id)
  end

  @doc """
  The column each visible task is in, as `%{task_id => column_id}`. Taken
  before a reload, so `prune/2` can tell which selected tasks moved.
  """
  def task_columns(socket) do
    socket.assigns
    |> Map.get(:visible_tasks_by_column, %{})
    |> Map.values()
    |> List.flatten()
    |> Map.new(&{&1.id, &1.column_id})
  end

  @doc """
  Keeps only the selected ids that are still visible on the board and still in
  the column they were in before this reload (`previous`, from
  `task_columns/1`), and turns selection mode off for a viewer who cannot
  modify it.

  A selected task that moved, by another session or a drag, leaves the
  selection with a flash saying so: acting on it would silently undo that
  move, for example a bulk move pulling it back out of Done.
  """
  def prune(socket, previous \\ %{}) do
    if socket.assigns[:can_modify] == true do
      {kept, moved} =
        split_selection(socket.assigns[:selected_ids], task_columns(socket), previous)

      socket
      |> assign(:selected_ids, MapSet.new(kept))
      |> flash_moved(length(moved))
    else
      reset(socket, false)
    end
  end

  # {still visible in the same column, visible but in another column}; ids
  # that are no longer visible are in neither.
  defp split_selection(nil, _current, _previous), do: {[], []}

  defp split_selection(selected, current, previous) do
    selected
    |> Enum.filter(&Map.has_key?(current, &1))
    |> Enum.split_with(&(Map.get(previous, &1, current[&1]) == current[&1]))
  end

  defp flash_moved(socket, 0), do: socket

  defp flash_moved(socket, count) do
    put_flash(
      socket,
      :info,
      ngettext(
        "A selected task moved to another column, so it was taken out of the selection.",
        "%{count} selected tasks moved to another column, so they were taken out of the selection.",
        count
      )
    )
  end

  @doc "Handles a `bulk_*` event from the board."
  def handle_bulk_event(event, params, socket) do
    with :ok <- check_modify(socket),
         :ok <- Plans.check_board(socket.assigns.board.id, :bulk_actions, surface: :live_view) do
      allowed(event, params, socket)
    else
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, permission_denied())}
      {:error, {:plan_required, :bulk_actions}} -> refuse_locked(event, socket)
    end
  end

  defp check_modify(socket),
    do: if(socket.assigns[:can_modify] == true, do: :ok, else: {:error, :unauthorized})

  # The board is free under enforcement. The Select toggle opens or closes
  # the locked prompt; the prompt says why, so it needs no flash. Any other
  # event is refused with a flash and opens the prompt. Either way a page
  # that loaded the board while it was paid leaves selection mode.
  defp refuse_locked("bulk_toggle_mode", socket),
    do: lock(socket, not toggle_active?(socket))

  defp refuse_locked(_event, socket) do
    socket
    |> put_flash(:error, bulk_locked_message())
    |> lock(true)
  end

  defp lock(socket, prompt_open?) do
    socket
    |> reset(false)
    |> assign(:bulk_locked?, true)
    |> assign(:bulk_prompt_open?, prompt_open?)
    |> restream()
  end

  # Whether the toggle shows as pressed: in selection mode, or with the
  # locked prompt open.
  defp toggle_active?(%{assigns: assigns}) do
    assigns[:selection_mode] == true or
      (assigns[:bulk_locked?] == true and assigns[:bulk_prompt_open?] == true)
  end

  # The plan check reads the board fresh, so a board moved into an
  # Organization since this page loaded unlocks on its next event. The
  # toggle acts on what it showed, so a click that closes an open prompt
  # does not start selection mode.
  defp allowed("bulk_toggle_mode", _params, socket) do
    entering? = not toggle_active?(socket)

    socket
    |> unlock()
    |> reset(entering?)
    |> maybe_load_options(entering?)
    |> restream()
  end

  defp allowed(event, params, socket), do: dispatch(event, params, unlock(socket))

  defp unlock(socket) do
    socket
    |> assign(:bulk_locked?, false)
    |> assign(:bulk_prompt_open?, false)
  end

  defp dispatch(event, params, %{assigns: %{selection_mode: true}} = socket),
    do: selection_event(event, params, socket)

  defp dispatch(_event, _params, socket), do: {:noreply, socket}

  defp selection_event("bulk_toggle", %{"id" => raw_id}, socket) do
    with {:ok, id} <- Show.parse_task_id(raw_id),
         true <- socket |> visible_ids() |> MapSet.member?(id) do
      socket
      |> update(:selected_ids, &toggle(&1, id))
      |> restream()
    else
      _ -> {:noreply, socket}
    end
  end

  defp selection_event("bulk_select_column", %{"id" => raw_id}, socket) do
    case Show.parse_task_id(raw_id) do
      {:ok, column_id} ->
        socket
        |> update(:selected_ids, &toggle_column(&1, column_task_ids(socket, column_id)))
        |> restream()

      :error ->
        {:noreply, socket}
    end
  end

  defp selection_event("bulk_clear", _params, socket),
    do: socket |> assign(:selected_ids, MapSet.new()) |> restream()

  defp selection_event("bulk_move", params, socket) do
    column_id = parse_id(params["column_id"])
    column = Enum.find(socket.assigns[:board_columns] || [], &(&1.id == column_id))
    column_name = column && ColumnActions.translate_column_name(column.name)

    run(
      socket,
      &Tasks.bulk_move_tasks(&1, &2, &3, column_id),
      %{column_id: column_id},
      &moved_message(&1, column_name)
    )
  end

  defp selection_event("bulk_assign", params, socket) do
    assignee_id = parse_assignee(params["assignee"])

    run(socket, &Tasks.bulk_assign_tasks(&1, &2, &3, assignee_id), %{}, fn n ->
      dngettext("tasks", "Assigned %{count} task", "Assigned %{count} tasks", n)
    end)
  end

  defp selection_event("bulk_add_label", params, socket) do
    label_id = parse_id(params["label_id"])

    run(socket, &Tasks.bulk_add_label(&1, &2, &3, label_id), %{}, fn n ->
      dngettext(
        "tasks",
        "Added the label to %{count} task",
        "Added the label to %{count} tasks",
        n
      )
    end)
  end

  defp selection_event("bulk_remove_label", params, socket) do
    label_id = parse_id(params["label_id"])

    run(socket, &Tasks.bulk_remove_label(&1, &2, &3, label_id), %{}, fn n ->
      dngettext(
        "tasks",
        "Removed the label from %{count} task",
        "Removed the label from %{count} tasks",
        n
      )
    end)
  end

  defp selection_event("bulk_archive", _params, socket) do
    run(socket, &Tasks.bulk_archive_tasks/3, %{}, fn n ->
      dngettext("tasks", "Archived %{count} task", "Archived %{count} tasks", n)
    end)
  end

  defp selection_event(_event, _params, socket), do: {:noreply, socket}

  # Runs a bulk action over the server-held selection and reports the result.
  defp run(socket, action, context, success_message) do
    %{current_scope: scope, board: board, selected_ids: selected} = socket.assigns

    case action.(scope, board, MapSet.to_list(selected)) do
      {:ok, result} -> handle_success(socket, result, success_message)
      {:error, reason} -> handle_error(socket, reason, context)
    end
  end

  defp handle_success(socket, %{count: count, skipped_goals: skipped}, success_message) do
    socket
    |> assign(:selected_ids, MapSet.new())
    |> put_flash(:info, join_messages(success_message.(count), skipped_message(skipped)))
    |> BoardState.reload_board_data()
  end

  defp handle_error(socket, :not_found, _context) do
    socket
    |> put_flash(
      :error,
      gettext("Some selected tasks are no longer on this board. Nothing was changed.")
    )
    |> BoardState.reload_board_data()
  end

  defp handle_error(socket, :wip_limit_reached, %{column_id: column_id}) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       gettext(
         "Cannot move the selected tasks: the column would exceed its WIP limit. Nothing was changed."
       )
     )
     |> push_event("wip_limit_violation", %{column_id: column_id})}
  end

  defp handle_error(socket, {:plan_required, :bulk_actions}, _context),
    do: refuse_locked(:action, socket)

  defp handle_error(socket, reason, _context),
    do: {:noreply, put_flash(socket, :error, error_message(reason))}

  defp error_message(:unauthorized), do: permission_denied()
  defp error_message(:empty_selection), do: gettext("Select at least one task")
  defp error_message(:invalid_column), do: gettext("Column not found on this board")
  defp error_message(:invalid_assignee), do: gettext("Choose a board member")
  defp error_message(:invalid_label), do: gettext("Label not found on this board")
  defp error_message(_reason), do: gettext("Bulk action failed. Nothing was changed.")

  defp moved_message(count, column_name) do
    bindings = [column: column_name]

    dngettext(
      "tasks",
      "Moved %{count} task to %{column}",
      "Moved %{count} tasks to %{column}",
      count,
      bindings
    )
  end

  defp skipped_message(0), do: nil

  defp skipped_message(count) do
    dngettext(
      "tasks",
      "%{count} goal was skipped: goals cannot be moved, assigned or archived in bulk.",
      "%{count} goals were skipped: goals cannot be moved, assigned or archived in bulk.",
      count
    )
  end

  defp join_messages(message, nil), do: message
  defp join_messages(message, extra), do: message <> " " <> extra

  defp permission_denied,
    do: gettext("You do not have permission to modify tasks on this board")

  defp bulk_locked_message,
    do: gettext("Bulk actions are available to organizations. Nothing was changed.")

  defp reset(socket, selection_mode) do
    socket
    |> assign(:selection_mode, selection_mode)
    |> assign(:selected_ids, MapSet.new())
  end

  # The bar's assignee and label selects reuse the filter bar's cached
  # options, which are loaded for the board view only.
  defp maybe_load_options(%{assigns: %{board: %{id: board_id}}} = socket, true) do
    case socket.assigns[:filter_options] do
      %{board_id: ^board_id} -> socket
      _ -> FilterActions.reload_options(socket, socket.assigns.board)
    end
  end

  defp maybe_load_options(socket, _entering?), do: socket

  defp restream(socket),
    do: {:noreply, stream(socket, :columns, socket.assigns[:board_columns] || [])}

  defp toggle(selected, id) do
    if MapSet.member?(selected, id),
      do: MapSet.delete(selected, id),
      else: MapSet.put(selected, id)
  end

  # Selects every visible card in the column, or clears them when they are
  # all selected already.
  defp toggle_column(selected, column_ids) do
    if column_ids != [] and Enum.all?(column_ids, &MapSet.member?(selected, &1)),
      do: MapSet.difference(selected, MapSet.new(column_ids)),
      else: MapSet.union(selected, MapSet.new(column_ids))
  end

  defp column_task_ids(socket, column_id) do
    socket.assigns
    |> Map.get(:visible_tasks_by_column, %{})
    |> Map.get(column_id, [])
    |> Enum.map(& &1.id)
  end

  defp visible_ids(socket) do
    socket.assigns
    |> Map.get(:visible_tasks_by_column, %{})
    |> Map.values()
    |> List.flatten()
    |> MapSet.new(& &1.id)
  end

  defp parse_id(value) do
    case Show.parse_task_id(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  # "unassigned" clears the assignee; anything that is not an id is refused
  # by BulkActions as an invalid assignee rather than read as "unassign".
  defp parse_assignee("unassigned"), do: nil
  defp parse_assignee(value), do: parse_id(value) || :invalid
end
