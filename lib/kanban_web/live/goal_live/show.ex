defmodule KanbanWeb.GoalLive.Show do
  @moduledoc """
  Per-goal view page rendered at `/boards/:id/goals/:goal_id`. Scaffold
  introduced in W551 — body composition (header / child tree / metadata
  panel / activity log) is wired up in W552.

  Mounts inside the `:require_authenticated_user` live_session, looks
  the board up scope-aware via `Kanban.Boards.get_board/2`, then loads
  the goal via `Kanban.Tasks.get_task_for_view/1` while verifying the
  goal belongs to that board and is of type `:goal`. Unauthorized or
  type-mismatched access redirects back to `/boards` with a flash —
  matching the contract that `BoardLive.Show.handle_board_not_found/1`
  uses for every other scope-protected board route.
  """
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Tasks
  alias KanbanWeb.GoalChildRow
  alias KanbanWeb.GoalProgressHeader
  alias KanbanWeb.TaskActivityLog
  alias KanbanWeb.TaskMetadataGrid

  @status_order [:backlog, :ready, :in_progress, :review, :completed]

  @impl true
  def mount(%{"id" => board_id, "goal_id" => goal_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, board} <- Boards.get_board(board_id, user),
         {:ok, goal} <- fetch_goal(goal_id, board.id) do
      children = Tasks.list_children_for_goal(user, goal.id)
      {:ok, assign_goal_view(socket, board, goal, children)}
    else
      _ -> {:ok, redirect_not_found(socket)}
    end
  end

  @impl true
  def handle_event("open_child", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/boards/#{socket.assigns.board}/tasks/#{id}/edit"
     )}
  end

  defp assign_goal_view(socket, board, goal, children) do
    by_status = group_by_status(children)
    flow = build_flow(by_status)

    socket
    |> assign(:board, board)
    |> assign(:goal, goal)
    |> assign(:children, children)
    |> assign(:children_by_status, by_status)
    |> assign(:flow, flow)
    |> assign(:status_sections, status_sections(by_status))
    |> assign(:page_title, page_title(goal))
  end

  defp redirect_not_found(socket) do
    socket
    |> put_flash(:error, gettext("Goal not found"))
    |> push_navigate(to: ~p"/boards")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} board={@board}>
      <:breadcrumbs>
        <.link navigate={~p"/boards"} style="color: var(--ink-3); text-decoration: none;">
          {gettext("Workspace")}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <.link navigate={~p"/boards"} style="color: var(--ink-3); text-decoration: none;">
          {gettext("Boards")}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <.link
          navigate={~p"/boards/#{@board}"}
          style="color: var(--ink-3); text-decoration: none;"
        >
          {@board.name}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <span class="ident" style="color: var(--ink); font-weight: 500;">
          {@goal.identifier}
        </span>
      </:breadcrumbs>

      <:actions>
        <.link navigate={~p"/boards/#{@board}"} class="btn btn-xs btn-ghost">
          {gettext("Back to board")}
        </.link>
      </:actions>

      <div data-goal-show class="stride-screen">
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />

        <div style="display: flex; align-items: stretch; min-height: 0;">
          <section
            data-goal-hierarchy
            style={[
              "flex: 1; padding: 14px 24px; overflow-y: auto;",
              "background: var(--surface);"
            ]}
          >
            <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 8px;">
              <span class="ucase" style="font-size: 10px; color: var(--ink-3);">
                {gettext("Hierarchy")}
              </span>
              <span class="ident" style="font-size: 11px; color: var(--ink-3);">
                {ngettext("%{count} child", "%{count} children", length(@children),
                  count: length(@children)
                )}
              </span>
            </div>

            <div
              :if={@children == []}
              style={[
                "padding: 24px; text-align: center;",
                "background: var(--surface-sunken); border-radius: 8px;",
                "color: var(--ink-3); font-size: 12px; font-style: italic;"
              ]}
            >
              {gettext("This goal has no children yet.")}
            </div>

            <div
              :if={@children != []}
              style={[
                "background: var(--surface); border: 1px solid var(--line);",
                "border-radius: 8px; overflow: hidden;"
              ]}
            >
              <div :for={{status, items} <- @status_sections}>
                <div style={[
                  "padding: 7px 14px; display: flex; align-items: center; gap: 8px;",
                  "background: var(--surface-sunken);",
                  "border-bottom: 1px solid var(--line);"
                ]}>
                  <span
                    aria-hidden="true"
                    style={[
                      "width: 6px; height: 6px; border-radius: 50%;",
                      "background: #{status_dot(status)};"
                    ]}
                  >
                  </span>
                  <span style="font-size: 11.5px; font-weight: 600; color: var(--ink);">
                    {status_label(status)}
                  </span>
                  <span class="ident" style="font-size: 11px; color: var(--ink-3);">
                    {length(items)}
                  </span>
                </div>
                <GoalChildRow.goal_child_row
                  :for={child <- items}
                  task={child}
                  on_click="open_child"
                />
              </div>
            </div>
          </section>

          <aside
            data-goal-meta
            style={[
              "width: 280px; flex-shrink: 0;",
              "border-left: 1px solid var(--line);",
              "background: var(--surface-2); padding: 16px 18px;"
            ]}
          >
            <TaskMetadataGrid.metadata_grid
              task={@goal}
              board_name={@board.name}
            />
          </aside>
        </div>

        <section
          data-goal-activity
          style={[
            "padding: 14px 24px; border-top: 1px solid var(--line);",
            "background: var(--surface);"
          ]}
        >
          <TaskActivityLog.activity_log histories={@goal.task_histories || []} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  # --- Private -----------------------------------------------------------

  defp fetch_goal(goal_id, board_id) do
    case parse_id(goal_id) do
      {:ok, id} ->
        case Tasks.get_task_for_view(id) do
          %{type: :goal, column: %{board_id: ^board_id}} = goal -> {:ok, goal}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp page_title(%{identifier: id, title: title}) when is_binary(id) and is_binary(title),
    do: "#{id} · #{title}"

  defp page_title(_), do: gettext("Goal")

  defp group_by_status(children) do
    Enum.group_by(children, &normalize_status(Map.get(&1, :status, :open)))
  end

  # The schema's :open status is the same bucket as the design's "backlog"
  # column — both surface unclaimed work. Collapse them so the per-status
  # section renders without leaving newly-created children behind.
  defp normalize_status(:open), do: :backlog
  defp normalize_status(other), do: other

  defp status_sections(by_status) do
    Enum.flat_map(@status_order, fn status ->
      case Map.get(by_status, status, []) do
        [] -> []
        items -> [{status, items}]
      end
    end)
  end

  defp build_flow(by_status) do
    counts = Map.new(@status_order, fn s -> {flow_key(s), length(Map.get(by_status, s, []))} end)
    Map.put(counts, :total, Enum.sum(Map.values(counts)))
  end

  defp flow_key(:in_progress), do: :doing
  defp flow_key(:completed), do: :done
  defp flow_key(other), do: other

  defp status_label(:backlog), do: gettext("Backlog")
  defp status_label(:ready), do: gettext("Ready")
  defp status_label(:in_progress), do: gettext("Doing")
  defp status_label(:review), do: gettext("Review")
  defp status_label(:completed), do: gettext("Done")
  defp status_label(_), do: gettext("Open")

  defp status_dot(:backlog), do: "var(--st-backlog)"
  defp status_dot(:ready), do: "var(--st-ready)"
  defp status_dot(:in_progress), do: "var(--st-doing)"
  defp status_dot(:review), do: "var(--st-review)"
  defp status_dot(:completed), do: "var(--st-done)"
  defp status_dot(_), do: "var(--ink-4)"
end
