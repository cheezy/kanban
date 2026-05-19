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
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.GoalChildRow
  alias KanbanWeb.GoalProgressHeader
  alias KanbanWeb.GoalSidebar
  alias KanbanWeb.TaskActivityLog

  # `:backlog` and `:in_progress` / `:completed` come straight from
  # `Task.status` (with `:open` normalised to `:backlog`). `:blocked` is
  # also a valid `Task.status` value — without it, blocked children would
  # be silently dropped from the per-status sections list. `:ready` and
  # `:review` are kept for forward compatibility with column-derived
  # status mapping; they are no-ops today since `Task.status` never holds
  # those values.
  @status_order [:backlog, :ready, :in_progress, :review, :completed, :blocked]

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
    contributors = contributors_for(goal, children)

    socket
    |> assign(:board, board)
    |> assign(:goal, goal)
    |> assign(:children, children)
    |> assign(:page_title, page_title(goal))
    |> assign_grouping(children)
    |> assign(:contributors, contributors)
    |> assign(:metrics, sidebar_metrics(goal, children, contributors))
  end

  defp assign_grouping(socket, children) do
    by_status = group_by_status(children)

    socket
    |> assign(:children_by_status, by_status)
    |> assign(:flow, build_flow(by_status))
    |> assign(:status_sections, status_sections(by_status))
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

      <div data-goal-show class="stride-screen">
        <header style={[
          "padding: 18px 28px 4px;",
          "display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;"
        ]}>
          <span style="flex: 1;" />
          <.link
            navigate={~p"/boards/#{@board}"}
            style={[
              "display: inline-flex; align-items: center; gap: 4px;",
              "font-size: 12px; color: var(--ink-2); text-decoration: none;"
            ]}
          >
            <.icon name="hero-arrow-left" class="w-3 h-3" /> {gettext("Back to Board")}
          </.link>
        </header>

        <GoalProgressHeader.goal_progress_header
          goal={@goal}
          flow={@flow}
          contributors={@contributors}
        />

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

          <GoalSidebar.goal_sidebar metrics={@metrics} />
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
    # Aggregate by `flow_key/1` so multiple `Task.status` values that map
    # to the same flow segment (e.g. `:blocked` rolling into `:backlog`)
    # sum their counts rather than clobbering each other.
    counts =
      Enum.reduce(@status_order, %{}, fn status, acc ->
        key = flow_key(status)
        n = length(Map.get(by_status, status, []))
        Map.update(acc, key, n, &(&1 + n))
      end)

    Map.put(counts, :total, Enum.sum(Map.values(counts)))
  end

  defp flow_key(:in_progress), do: :doing
  defp flow_key(:completed), do: :done
  # Blocked work is unfinished and waiting on something; surface it under
  # the backlog segment of the progress bar.
  defp flow_key(:blocked), do: :backlog
  defp flow_key(other), do: other

  defp status_label(:backlog), do: gettext("Backlog")
  defp status_label(:ready), do: gettext("Ready")
  defp status_label(:in_progress), do: gettext("Doing")
  defp status_label(:review), do: gettext("Review")
  defp status_label(:completed), do: gettext("Done")
  defp status_label(:blocked), do: gettext("Blocked")
  defp status_label(_), do: gettext("Open")

  defp status_dot(:backlog), do: "var(--st-backlog)"
  defp status_dot(:ready), do: "var(--st-ready)"
  defp status_dot(:in_progress), do: "var(--st-doing)"
  defp status_dot(:review), do: "var(--st-review)"
  defp status_dot(:completed), do: "var(--st-done)"
  defp status_dot(:blocked), do: "var(--st-blocked)"
  defp status_dot(_), do: "var(--ink-4)"

  # Distinct list of humans + agents who touched the goal or any of its
  # children — drives the "Working on it" MemberStack in the hero band.
  # Order: humans (in goal-first, child-position order) then agents.
  defp contributors_for(goal, children) do
    tasks = [goal | children]
    human_avatars(tasks) ++ agent_avatars(tasks)
  end

  defp human_avatars(tasks) do
    tasks
    |> Enum.flat_map(&users_from/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&user_to_avatar/1)
  end

  defp agent_avatars(tasks) do
    tasks
    |> Enum.flat_map(&agents_from/1)
    |> Enum.uniq()
    |> Enum.map(&agent_to_avatar/1)
  end

  defp users_from(task) do
    Enum.reject(
      [Map.get(task, :assigned_to), Map.get(task, :created_by)],
      &(is_nil(&1) or match?(%Ecto.Association.NotLoaded{}, &1))
    )
  end

  defp agents_from(task) do
    [Map.get(task, :created_by_agent), Map.get(task, :completed_by_agent)]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp user_to_avatar(user) do
    %{
      kind: :human,
      name: user.name || user.email || "?",
      palette: AvatarPalette.for_human(user.id)
    }
  end

  defp agent_to_avatar(name) do
    %{kind: :agent, name: name, palette: AvatarPalette.for_agent(name)}
  end

  # --- Sidebar metric pack ---------------------------------------------

  defp sidebar_metrics(goal, children, contributors) do
    counts = sidebar_counts(children, length(contributors))

    counts
    |> Map.merge(sidebar_time_metrics(goal, children))
    |> Map.merge(sidebar_velocity(goal, children))
  end

  defp sidebar_counts(children, contributor_count) do
    statuses = Enum.frequencies_by(children, &Map.get(&1, :status, :open))
    backlog = Map.get(statuses, :backlog, 0) + Map.get(statuses, :open, 0)
    ready = Map.get(statuses, :ready, 0)
    in_flight = Map.get(statuses, :in_progress, 0) + Map.get(statuses, :review, 0)
    blocked = Map.get(statuses, :blocked, 0)
    done = Map.get(statuses, :completed, 0)
    total = length(children)
    percent = if total > 0, do: round(done / total * 100), else: 0

    %{
      percent: percent,
      done: done,
      total: total,
      in_flight: in_flight,
      ready: ready,
      backlog: backlog,
      blocked: blocked,
      contributor_count: contributor_count
    }
  end

  defp sidebar_time_metrics(goal, children) do
    completed = Enum.filter(children, &(Map.get(&1, :status) == :completed))
    total_minutes = sum_time_spent(children)
    done_count = length(completed)

    %{
      days_in_flight: days_in_flight(goal, children),
      time_spent_minutes: total_minutes,
      avg_cycle_minutes: avg_minutes(sum_time_spent(completed), done_count),
      last_activity: last_activity(goal, children)
    }
  end

  defp days_in_flight(goal, children) do
    earliest =
      [goal | children]
      |> Enum.map(&Map.get(&1, :claimed_at))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    case earliest do
      nil -> nil
      %DateTime{} = dt -> max(DateTime.diff(DateTime.utc_now(), dt, :second) |> div(86_400), 0)
    end
  end

  defp sum_time_spent(tasks) do
    tasks
    |> Enum.map(&Map.get(&1, :time_spent_minutes))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp avg_minutes(_total, 0), do: nil
  defp avg_minutes(total, count), do: div(total, count)

  defp last_activity(goal, children) do
    [goal | children]
    |> Enum.map(&Map.get(&1, :updated_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(NaiveDateTime, fn -> nil end)
  end

  # --- Velocity sparkline -----------------------------------------------

  @bucket_count 12

  # Distribution of completions across the last 12 time units. Unit
  # auto-adapts: hourly when the earliest activity (goal claim or any
  # child completion) is within the last 24 hours, daily otherwise.
  # Returns `:sparkline_data` (a list of integers) and
  # `:sparkline_label` (the human-readable range for the caption).
  defp sidebar_velocity(goal, children) do
    now = DateTime.utc_now()
    completions = completed_at_list(children)
    earliest = earliest_signal(goal, children)
    unit = bucket_unit(earliest, now)
    buckets = bucketize(completions, unit, now)

    %{
      sparkline_data: buckets,
      sparkline_label: bucket_label(unit, now),
      sparkline_unit: unit
    }
  end

  defp completed_at_list(children) do
    children
    |> Enum.map(&Map.get(&1, :completed_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_datetime/1)
  end

  defp earliest_signal(goal, children) do
    candidates =
      [Map.get(goal, :claimed_at), Map.get(goal, :inserted_at) | completed_at_list(children)]
      |> Enum.map(&to_datetime/1)
      |> Enum.reject(&is_nil/1)

    Enum.min(candidates, DateTime, fn -> nil end)
  end

  defp bucket_unit(nil, _now), do: :hour

  defp bucket_unit(%DateTime{} = earliest, now) do
    if DateTime.diff(now, earliest, :second) <= 86_400, do: :hour, else: :day
  end

  defp bucketize(completions, :hour, now) do
    bucket_indexes(completions, now, 3600)
  end

  defp bucketize(completions, :day, now) do
    bucket_indexes(completions, now, 86_400)
  end

  # For each completion, the bucket index is floor((now - completed_at) / size).
  # Index 0 is the most recent bucket. We then reverse so the oldest sits on
  # the left of the sparkline (which is how PulseSparkline reads its data).
  defp bucket_indexes(completions, now, size_seconds) do
    counts = List.duplicate(0, @bucket_count)

    Enum.reduce(completions, counts, fn dt, acc ->
      idx = div(DateTime.diff(now, dt, :second), size_seconds)
      if idx in 0..(@bucket_count - 1), do: List.update_at(acc, idx, &(&1 + 1)), else: acc
    end)
    |> Enum.reverse()
  end

  defp bucket_label(:hour, now) do
    earliest = DateTime.add(now, -@bucket_count * 3600, :second)
    "#{format_clock(earliest)} — #{format_clock(now)}"
  end

  defp bucket_label(:day, now) do
    earliest = DateTime.add(now, -@bucket_count * 86_400, :second)
    "#{format_short_date(earliest)} — #{format_short_date(now)}"
  end

  defp format_clock(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp format_short_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d")

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(_), do: nil
end
