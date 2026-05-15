defmodule KanbanWeb.AgentActivityRail do
  @moduledoc """
  Right-side rail surfacing recent agent activity on a board (claims,
  completions, reviews). Collapsible: when collapsed it shrinks to a
  thin 32px strip that just exposes the toggle, reclaiming ~280px of
  horizontal real-estate for the kanban columns.

  The expanded rail renders a chronological event stream derived from
  the same tasks the board already loaded — no extra queries — so it
  stays cheap to keep mounted alongside the kanban columns.
  """
  use KanbanWeb, :html

  @doc """
  Renders the collapsible agent-activity rail.

  ## Attrs

    * `tasks_by_column` — the LiveView's `:tasks_by_column` map. Used
      to derive recent claim / complete events without an extra query.
    * `collapsed` — boolean; when true, render only the toggle strip.
      Defaults to `false`.
    * `limit` — max number of recent events to render. Default 30.
  """
  attr :tasks_by_column, :map, required: true
  attr :collapsed, :boolean, default: false
  attr :limit, :integer, default: 30

  def rail(assigns) do
    events =
      assigns.tasks_by_column
      |> recent_events()
      |> Enum.take(assigns.limit)

    assigns = assign(assigns, :events, events)

    ~H"""
    <aside
      aria-label={gettext("Agent activity")}
      style={[
        "flex-shrink: 0;",
        "width: #{if @collapsed, do: 32, else: 280}px;",
        "background: var(--surface);",
        "border: 1px solid var(--line);",
        "border-radius: 12px;",
        "display: flex; flex-direction: column;",
        "overflow: hidden; min-height: 0;",
        "transition: width 0.2s cubic-bezier(0.4, 0, 0.2, 1);"
      ]}
    >
      <button
        type="button"
        phx-click="toggle_agent_rail"
        aria-expanded={"#{not @collapsed}"}
        aria-label={
          if @collapsed,
            do: gettext("Expand agent activity"),
            else: gettext("Collapse agent activity")
        }
        class="tooltip tooltip-left"
        data-tip={
          if @collapsed,
            do: gettext("Expand agent activity"),
            else: gettext("Collapse agent activity")
        }
        style={[
          "display: flex; align-items: center;",
          "justify-content: #{if @collapsed, do: "center", else: "space-between"};",
          "padding: #{if @collapsed, do: "8px 4px", else: "10px 12px"};",
          "background: transparent; border: none; cursor: pointer;",
          "color: var(--ink-2); width: 100%;",
          "border-bottom: 1px solid var(--line);"
        ]}
      >
        <span
          :if={not @collapsed}
          class="ucase"
          style="font-size: 10.5px; font-weight: 600; letter-spacing: 0.04em;"
        >
          {gettext("Agent activity")}
        </span>
        <.icon
          name={if @collapsed, do: "hero-chevron-left", else: "hero-chevron-right"}
          class="w-3.5 h-3.5"
        />
      </button>

      <div
        :if={not @collapsed}
        style={[
          "flex: 1; min-height: 0; overflow-y: auto;",
          "padding: 8px 4px;"
        ]}
      >
        <%= if @events == [] do %>
          <p style="margin: 12px 12px; font-size: 11.5px; color: var(--ink-3); line-height: 1.4;">
            {gettext("No recent activity. Claim and complete events will appear here.")}
          </p>
        <% else %>
          <ul style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 2px;">
            <li :for={evt <- @events}>
              <.event_row event={evt} />
            </li>
          </ul>
        <% end %>
      </div>
    </aside>
    """
  end

  attr :event, :map, required: true

  defp event_row(assigns) do
    ~H"""
    <div style={[
      "display: flex; align-items: flex-start; gap: 8px;",
      "padding: 6px 10px; border-radius: 4px;",
      "font-size: 11.5px; line-height: 1.35; color: var(--ink-2);"
    ]}>
      <.event_icon kind={@event.kind} />
      <div style="flex: 1; min-width: 0;">
        <div
          style="display: flex; align-items: center; gap: 6px; font-size: 10.5px; color: var(--ink-3);"
          class="ident"
        >
          <span>{@event.identifier}</span>
          <span>·</span>
          <span>{format_relative(@event.at)}</span>
        </div>
        <div style="margin-top: 2px; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;">
          {event_summary(@event)}
        </div>
        <div
          :if={@event.agent}
          style="margin-top: 2px; font-size: 10.5px; color: var(--ink-3); font-style: italic;"
        >
          {@event.agent}
        </div>
      </div>
    </div>
    """
  end

  attr :kind, :atom, required: true

  defp event_icon(%{kind: :complete} = assigns) do
    ~H"""
    <span style="color: var(--st-done); display: inline-flex; margin-top: 1px;">
      <.icon name="hero-check-circle" class="w-3.5 h-3.5" />
    </span>
    """
  end

  defp event_icon(%{kind: :claim} = assigns) do
    ~H"""
    <span style="color: var(--st-doing); display: inline-flex; margin-top: 1px;">
      <.icon name="hero-cursor-arrow-rays" class="w-3.5 h-3.5" />
    </span>
    """
  end

  defp event_icon(assigns) do
    ~H"""
    <span style="color: var(--ink-3); display: inline-flex; margin-top: 1px;">
      <.icon name="hero-clock" class="w-3.5 h-3.5" />
    </span>
    """
  end

  defp event_summary(%{kind: :complete, title: title}),
    do: gettext("Completed %{title}", title: title)

  defp event_summary(%{kind: :claim, title: title}),
    do: gettext("Claimed %{title}", title: title)

  defp event_summary(%{title: title}), do: title

  # Build a chronological event stream from tasks. Each task with a
  # `completed_at` produces a :complete event; each unfinished task
  # with a `claimed_at` produces a :claim event. Events are sorted
  # newest-first by their timestamp.
  defp recent_events(tasks_by_column) do
    tasks_by_column
    |> flatten_tasks()
    |> Enum.flat_map(&events_for_task/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp flatten_tasks(tasks_by_column) do
    tasks_by_column
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(Map.get(&1, :type) == :goal))
  end

  defp events_for_task(task) do
    completed_at = Map.get(task, :completed_at)
    claimed_at = Map.get(task, :claimed_at)

    cond do
      not is_nil(completed_at) -> [complete_event(task, completed_at)]
      not is_nil(claimed_at) -> [claim_event(task, claimed_at)]
      true -> []
    end
  end

  defp complete_event(task, at) do
    %{
      kind: :complete,
      identifier: task_identifier(task),
      title: task_title(task),
      agent: Map.get(task, :completed_by_agent),
      at: at
    }
  end

  defp claim_event(task, at) do
    %{
      kind: :claim,
      identifier: task_identifier(task),
      title: task_title(task),
      agent: nil,
      at: at
    }
  end

  defp task_identifier(task), do: Map.get(task, :identifier) || "?"
  defp task_title(task), do: Map.get(task, :title) || "—"

  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n}m ago", n: div(diff, 60))
      diff < 86_400 -> gettext("%{n}h ago", n: div(diff, 3600))
      true -> gettext("%{n}d ago", n: div(diff, 86_400))
    end
  end

  defp format_relative(_), do: ""
end
