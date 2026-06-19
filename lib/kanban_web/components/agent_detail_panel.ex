defmodule KanbanWeb.AgentDetailPanel do
  @moduledoc """
  View-only drill-down panel for a single agent.

  Renders the map returned by `Kanban.Agents.agent_detail/2` — the agent's
  current work, claim history, failures, and recent activity — using the
  existing `stride-screen` design tokens so it reads correctly in light and
  dark mode. Purely presentational: no control actions and no transcript or
  token-level detail. The caller passes the `:detail` map via an attr.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskTokens

  @doc """
  Renders the agent detail panel.

  ## Attrs

    * `detail` — the map returned by `Kanban.Agents.agent_detail/2`:
      `%{name, current_task, claims, failures, recent_activity}`. Required.
      Each `claims`/`failures` entry is `%{identifier, title, at}` and each
      `recent_activity` entry is a `Kanban.Agents.Event`. `current_task` is
      `nil` when the agent holds no active task; the lists may be empty.
  """
  attr :detail, :map, required: true

  def panel(assigns) do
    ~H"""
    <section
      data-agent-detail-panel
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 16px;",
        "padding: 16px;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 10px;"
      ]}
    >
      <h2
        data-agent-detail-name
        style={[
          "margin: 0;",
          "font-size: 15px; font-weight: 600; letter-spacing: -0.01em;",
          "color: var(--ink);"
        ]}
      >
        {@detail.name}
      </h2>

      <div data-agent-detail-current style="display: flex; flex-direction: column; gap: 6px;">
        <.section_heading label={gettext("Current work")} />
        <div
          :if={@detail.current_task}
          style="display: flex; align-items: baseline; gap: 8px; font-size: 13px;"
        >
          <span style="font-weight: 600; letter-spacing: 0.02em; color: var(--ink);">
            {@detail.current_task.identifier}
          </span>
          <span style="color: var(--ink-2);">{@detail.current_task.title}</span>
        </div>
        <p
          :if={is_nil(@detail.current_task)}
          data-agent-detail-no-current
          style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
        >
          {gettext("No active task")}
        </p>
      </div>

      <.ref_section
        marker="claims"
        label={gettext("Claims")}
        entries={@detail.claims}
        tone="var(--ink)"
      />

      <.ref_section
        marker="failures"
        label={gettext("Failures")}
        entries={@detail.failures}
        tone="var(--st-blocked)"
      />

      <div data-agent-detail-activity style="display: flex; flex-direction: column; gap: 6px;">
        <.section_heading label={gettext("Recent activity")} count={length(@detail.recent_activity)} />
        <ul
          :if={@detail.recent_activity != []}
          style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px;"
        >
          <.event_row :for={event <- @detail.recent_activity} event={event} />
        </ul>
        <p
          :if={@detail.recent_activity == []}
          style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
        >
          {gettext("No recent activity.")}
        </p>
      </div>
    </section>
    """
  end

  # A section of task references (claims or failures) with a count and an
  # empty-state caption. `tone` colors the identifier so failures read as the
  # danger palette while claims stay neutral ink.
  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :entries, :list, required: true
  attr :tone, :string, required: true

  defp ref_section(assigns) do
    ~H"""
    <div
      data-agent-detail-section={@marker}
      style="display: flex; flex-direction: column; gap: 6px;"
    >
      <.section_heading label={@label} count={length(@entries)} />
      <ul
        :if={@entries != []}
        style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 4px;"
      >
        <li
          :for={entry <- @entries}
          data-agent-detail-ref
          style="display: flex; align-items: baseline; gap: 8px; font-size: 12px;"
        >
          <span style={["font-weight: 600; letter-spacing: 0.02em;", "color: #{@tone};"]}>
            {entry.identifier}
          </span>
          <span style="flex: 1; min-width: 0; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {entry.title}
          </span>
          <time
            datetime={DateTime.to_iso8601(entry.at)}
            style="color: var(--ink-3); font-variant-numeric: tabular-nums; white-space: nowrap;"
          >
            {format_at(entry.at)}
          </time>
        </li>
      </ul>
      <p
        :if={@entries == []}
        style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
      >
        {gettext("None")}
      </p>
    </div>
    """
  end

  # A single recent-activity event row, mirroring the activity feed: a colored
  # verb, the identifier, the title, and the timestamp.
  attr :event, :map, required: true

  defp event_row(assigns) do
    ~H"""
    <li
      data-agent-detail-event={@event.kind}
      style="display: flex; align-items: baseline; gap: 6px; font-size: 12px;"
    >
      <span style={["font-weight: 500;", "color: #{TaskTokens.kind_tone(@event.kind)};"]}>
        {TaskTokens.kind_label(@event.kind)}
      </span>
      <span
        :if={@event.identifier}
        style="font-weight: 600; letter-spacing: 0.02em; color: var(--ink);"
      >
        {@event.identifier}
      </span>
      <span
        :if={@event.title}
        style="flex: 1; min-width: 0; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
      >
        {@event.title}
      </span>
      <time
        datetime={DateTime.to_iso8601(@event.at)}
        style="color: var(--ink-3); font-variant-numeric: tabular-nums; white-space: nowrap;"
      >
        {format_at(@event.at)}
      </time>
    </li>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, default: nil

  defp section_heading(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style={[
        "font-size: 10px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.04em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </span>
      <span
        :if={@count}
        style={[
          "font-size: 10px; font-weight: 600;",
          "color: var(--ink-3); font-variant-numeric: tabular-nums;"
        ]}
      >
        {@count}
      </span>
    </div>
    """
  end

  # Compact "month day, HH:MM" UTC label. Claim/failure/activity timestamps can
  # span days, so the date is shown alongside the time (the feed uses HH:MM
  # alone because it is a 24-hour window).
  defp format_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %H:%M")
end
