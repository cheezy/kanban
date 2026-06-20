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
      `%{name, current_task, claims, failures, recent_activity, activity_series,
      outcome}`. Required. Each `claims`/`failures` entry is
      `%{identifier, title, at}` and each `recent_activity` entry is a
      `Kanban.Agents.Event`. `activity_series` is a `[%{date, count}]` list of
      daily completions (for the sparkline) and `outcome` is
      `%{approved, rejected, in_progress, success_rate}` (for the donut).
      `current_task` is `nil` when the agent holds no active task; the lists
      may be empty.
    * `expanded_sections` — a `MapSet` of the section keys (`"current"`,
      `"claims"`, `"failures"`, `"activity"`) that are currently expanded.
      `nil` (the default) means every section is expanded, so the component
      renders fully when used standalone.
    * `on_toggle` — the `phx-click` event name a section's title row fires to
      collapse/expand itself (with `phx-value-section`). `nil` (the default)
      renders the title rows as inert buttons, for standalone/preview use.
  """
  attr :detail, :map, required: true
  attr :expanded_sections, :any, default: nil
  attr :on_toggle, :string, default: nil

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

      <.activity_charts series={@detail.activity_series} outcome={@detail.outcome} />

      <div data-agent-detail-current style="display: flex; flex-direction: column; gap: 6px;">
        <.section_heading
          label={gettext("Current work")}
          section="current"
          expanded={expanded?(@expanded_sections, "current")}
          on_toggle={@on_toggle}
          highlight_soft={TaskTokens.kind_soft(:claim)}
          highlight_tone={TaskTokens.kind_tone(:claim)}
        />
        <div
          :if={@detail.current_task && expanded?(@expanded_sections, "current")}
          style="display: flex; align-items: baseline; gap: 8px; font-size: 13px;"
        >
          <span style="font-weight: 600; letter-spacing: 0.02em; color: var(--ink);">
            {@detail.current_task.identifier}
          </span>
          <span style="color: var(--ink-2);">{@detail.current_task.title}</span>
        </div>
        <p
          :if={is_nil(@detail.current_task) && expanded?(@expanded_sections, "current")}
          data-agent-detail-no-current
          style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
        >
          {gettext("No active task")}
        </p>
      </div>

      <.ref_section
        marker="claims"
        section="claims"
        label={gettext("Claims")}
        entries={@detail.claims}
        tone="var(--ink)"
        expanded={expanded?(@expanded_sections, "claims")}
        on_toggle={@on_toggle}
        highlight_soft={TaskTokens.kind_soft(:claim)}
        highlight_tone={TaskTokens.kind_tone(:claim)}
      />

      <.ref_section
        marker="failures"
        section="failures"
        label={gettext("Failures")}
        entries={@detail.failures}
        tone="var(--st-blocked)"
        expanded={expanded?(@expanded_sections, "failures")}
        on_toggle={@on_toggle}
        highlight_soft={TaskTokens.status_soft(:blocked)}
        highlight_tone={TaskTokens.status_ink(:blocked)}
      />

      <div data-agent-detail-activity style="display: flex; flex-direction: column; gap: 6px;">
        <.section_heading
          label={gettext("Recent activity")}
          count={length(@detail.recent_activity)}
          section="activity"
          expanded={expanded?(@expanded_sections, "activity")}
          on_toggle={@on_toggle}
          highlight_soft="var(--surface-sunken)"
          highlight_tone="var(--ink-3)"
        />
        <ul
          :if={@detail.recent_activity != [] && expanded?(@expanded_sections, "activity")}
          style="margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px;"
        >
          <.event_row :for={event <- @detail.recent_activity} event={event} />
        </ul>
        <p
          :if={@detail.recent_activity == [] && expanded?(@expanded_sections, "activity")}
          style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
        >
          {gettext("No recent activity.")}
        </p>
      </div>
    </section>
    """
  end

  # An at-a-glance visual band under the agent name: a daily-completion
  # sparkline (mirroring the page's Delivery-trends bars) and a success-rate
  # donut. Both reuse the data computed in `Kanban.Agents.agent_detail/2`. When
  # the agent has no completions in the window and no reviewed/active tasks, a
  # single muted caption stands in for the charts.
  attr :series, :list, required: true
  attr :outcome, :map, required: true

  defp activity_charts(assigns) do
    max_count =
      case Enum.map(assigns.series, & &1.count) do
        [] -> 0
        counts -> Enum.max(counts)
      end

    reviewed = assigns.outcome.approved + assigns.outcome.rejected

    assigns =
      assign(assigns,
        max_count: max_count,
        reviewed: reviewed,
        pct: round(assigns.outcome.success_rate * 100)
      )

    ~H"""
    <div
      data-agent-detail-charts
      style="display: flex; align-items: flex-end; gap: 16px; flex-wrap: wrap;"
    >
      <p
        :if={@max_count == 0 and @reviewed == 0 and @outcome.in_progress == 0}
        data-agent-detail-charts-empty
        style={["margin: 0;", "font-size: 12px; font-style: italic; color: var(--ink-3);"]}
      >
        {gettext("No activity yet.")}
      </p>

      <div
        :if={@max_count > 0}
        data-agent-detail-sparkline
        aria-label={gettext("Daily completions over the last %{days} days", days: length(@series))}
        style="display: flex; align-items: flex-end; gap: 2px; height: 56px; overflow-x: auto;"
      >
        <span
          :for={entry <- @series}
          data-agent-detail-spark-bar={Date.to_iso8601(entry.date)}
          aria-hidden="true"
          style={[
            "width: 7px; flex: none; border-radius: 2px 2px 0 0;",
            "background: var(--st-done);",
            "height: #{spark_height(entry.count, @max_count)}px;"
          ]}
        />
      </div>

      <div
        :if={@reviewed > 0 or @outcome.in_progress > 0}
        data-agent-detail-success
        style="display: inline-flex; align-items: center; gap: 8px;"
      >
        <svg
          width="44"
          height="44"
          viewBox="0 0 40 40"
          role="img"
          aria-label={gettext("Success rate")}
        >
          <circle cx="20" cy="20" r="16" fill="none" stroke="var(--surface-sunken)" stroke-width="5" />
          <circle
            :if={@reviewed > 0}
            cx="20"
            cy="20"
            r="16"
            fill="none"
            stroke="var(--st-done)"
            stroke-width="5"
            stroke-linecap="round"
            stroke-dasharray={donut_dasharray(@outcome.success_rate)}
            transform="rotate(-90 20 20)"
          />
        </svg>
        <div style="display: flex; flex-direction: column;">
          <span style={[
            "font-size: 14px; font-weight: 600; color: var(--ink);",
            "font-variant-numeric: tabular-nums;"
          ]}>
            {if @reviewed > 0, do: "#{@pct}%", else: "—"}
          </span>
          <span style={[
            "font-size: 9px; font-weight: 600;",
            "text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3);"
          ]}>
            {gettext("Success")}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Sparkline bar height in px, mirroring the Delivery-trends `bar_height/2`
  # formula but scaled to the panel's 56px band: a non-zero day is at least 3px
  # tall so a single completion is still visible.
  defp spark_height(count, max) when is_integer(count) and is_integer(max) and max > 0 do
    max(3, round(count / max * 36))
  end

  defp spark_height(_count, _max), do: 0

  # The `stroke-dasharray` for the donut arc: the approved share of the ring's
  # circumference, then the full circumference (the remainder stays the track).
  defp donut_dasharray(success_rate) do
    circumference = 2 * :math.pi() * 16
    filled = success_rate * circumference
    "#{Float.round(filled, 2)} #{Float.round(circumference, 2)}"
  end

  # A section of task references (claims or failures) with a count and an
  # empty-state caption. `tone` colors the identifier so failures read as the
  # danger palette while claims stay neutral ink. The title row is a collapse
  # toggle (see `section_heading/1`); its body is guarded by `@expanded`.
  attr :marker, :string, required: true
  attr :section, :string, required: true
  attr :label, :string, required: true
  attr :entries, :list, required: true
  attr :tone, :string, required: true
  attr :expanded, :boolean, default: true
  attr :on_toggle, :string, default: nil
  attr :highlight_soft, :string, default: nil
  attr :highlight_tone, :string, default: nil

  defp ref_section(assigns) do
    ~H"""
    <div
      data-agent-detail-section={@marker}
      style="display: flex; flex-direction: column; gap: 6px;"
    >
      <.section_heading
        label={@label}
        count={length(@entries)}
        section={@section}
        expanded={@expanded}
        on_toggle={@on_toggle}
        highlight_soft={@highlight_soft}
        highlight_tone={@highlight_tone}
      />
      <ul
        :if={@entries != [] && @expanded}
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
        :if={@entries == [] && @expanded}
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

  # The clickable title row for a detail-panel section. Mirrors the dormant-
  # agents collapse on the roster: a full-width button with a chevron that
  # flips hero-chevron-down (expanded) / hero-chevron-right (collapsed) and an
  # `aria-expanded` reflecting state. The row carries the activity-list
  # highlight — `highlight_soft` as the row band and `highlight_tone` as the
  # left accent (and chevron color, inherited via the button's `color`) — both
  # theme-aware tokens from `TaskTokens`, never a hardcoded color.
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :section, :string, default: nil
  attr :expanded, :boolean, default: true
  attr :on_toggle, :string, default: nil
  attr :highlight_soft, :string, default: nil
  attr :highlight_tone, :string, default: nil

  defp section_heading(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_toggle}
      phx-value-section={@section}
      data-agent-detail-section-toggle={@section}
      aria-expanded={to_string(@expanded)}
      class="focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style={[
        "display: flex; align-items: center; gap: 6px;",
        "width: 100%; padding: 4px 8px;",
        "border: 0; border-left: 3px solid #{@highlight_tone || "transparent"};",
        "border-radius: 4px; cursor: pointer; text-align: left;",
        "background: #{@highlight_soft || "transparent"};",
        "color: #{@highlight_tone || "var(--ink-3)"};"
      ]}
    >
      <.icon
        name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
        class="w-3 h-3"
      />
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
    </button>
    """
  end

  # Whether a detail-panel section is currently expanded. A `nil` set (the
  # component's default) means every section is expanded, so the panel renders
  # fully when used standalone (e.g. in component tests/previews).
  defp expanded?(nil, _section), do: true
  defp expanded?(%MapSet{} = sections, section), do: MapSet.member?(sections, section)

  # Compact "month day, HH:MM" UTC label. Claim/failure/activity timestamps can
  # span days, so the date is shown alongside the time (the feed uses HH:MM
  # alone because it is a 24-hour window).
  defp format_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %H:%M")
end
