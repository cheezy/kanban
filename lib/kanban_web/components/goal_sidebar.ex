defmodule KanbanWeb.GoalSidebar do
  @moduledoc """
  Right-rail metrics summary for the per-goal view page.

  Surfaces two stacked sections:

    * **Progress** — percent complete, done/total, in-flight (doing +
      review), ready, blocked, contributor count.
    * **Time** — days in flight (since the earliest child claim),
      total time spent across children, average cycle time per done
      child, and the last activity timestamp.

  Pure presentation: every count and timestamp is computed by the
  caller and passed in via the `:metrics` map. The LiveView owns the
  derivation so the component stays trivially testable.
  """
  use KanbanWeb, :html

  alias KanbanWeb.PulseSparkline

  @doc """
  Renders the goal-sidebar metric pack.

  ## Attrs

    * `metrics` — required map with keys:
      - `:percent` (integer 0-100)
      - `:done`, `:total`, `:in_flight`, `:ready`, `:backlog`,
        `:blocked`, `:contributor_count` (integers)
      - `:days_in_flight` (integer or nil if not yet started)
      - `:time_spent_minutes` (integer)
      - `:avg_cycle_minutes` (integer or nil if no completed children)
      - `:last_activity` (`DateTime`, `NaiveDateTime`, or nil)
  """
  attr :metrics, :map, required: true

  def goal_sidebar(assigns) do
    ~H"""
    <aside
      data-goal-sidebar
      class="stride-screen"
      style={[
        "width: 280px; flex-shrink: 0;",
        "border-left: 1px solid var(--line);",
        "background: var(--surface-2);",
        "padding: 16px 18px;",
        "display: flex; flex-direction: column; gap: 18px;"
      ]}
    >
      <.velocity
        data={@metrics.sparkline_data}
        label={@metrics.sparkline_label}
        unit={@metrics.sparkline_unit}
      />

      <.section title={gettext("Progress")}>
        <.headline_metric label={gettext("Complete")} value={"#{@metrics.percent}%"} />
        <.metric_row label={gettext("Done / total")} value={"#{@metrics.done}/#{@metrics.total}"} />
        <.metric_row
          label={gettext("In flight")}
          value={@metrics.in_flight}
          tone="var(--st-doing)"
        />
        <.metric_row label={gettext("Ready")} value={@metrics.ready} tone="var(--st-ready)" />
        <.metric_row
          :if={@metrics.blocked > 0}
          label={gettext("Blocked")}
          value={@metrics.blocked}
          tone="var(--st-blocked)"
        />
        <.metric_row label={gettext("Contributors")} value={@metrics.contributor_count} />
      </.section>

      <.section title={gettext("Time")}>
        <.metric_row
          label={gettext("Days in flight")}
          value={format_days(@metrics.days_in_flight)}
        />
        <.metric_row
          label={gettext("Time spent")}
          value={format_duration(@metrics.time_spent_minutes)}
        />
        <.metric_row
          label={gettext("Avg cycle")}
          value={format_duration(@metrics.avg_cycle_minutes)}
        />
        <.metric_row
          label={gettext("Last activity")}
          value={format_relative(@metrics.last_activity)}
        />
      </.section>
    </aside>
    """
  end

  # --- Sub-components ----------------------------------------------------

  attr :data, :list, required: true
  attr :label, :string, required: true
  attr :unit, :atom, required: true

  defp velocity(assigns) do
    assigns = assign(assigns, :heading, heading_for(assigns.unit))

    ~H"""
    <div data-goal-velocity style="display: flex; flex-direction: column; gap: 6px;">
      <div class="ucase" style="font-size: 9.5px; color: var(--ink-3);">
        {@heading}
      </div>
      <PulseSparkline.pulse_sparkline
        data={@data}
        color="var(--stride-violet)"
        width={244}
        height={42}
      />
      <div style={[
        "display: flex; justify-content: space-between;",
        "font-size: 10px; color: var(--ink-3);",
        "font-family: var(--font-mono);"
      ]}>
        <span>{@label}</span>
      </div>
    </div>
    """
  end

  defp heading_for(:hour), do: gettext("Throughput · last 12 hours")
  defp heading_for(_), do: gettext("Throughput · last 12 days")

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 8px;">
      <div class="ucase" style="font-size: 9.5px; color: var(--ink-3);">
        {@title}
      </div>
      <div style="display: flex; flex-direction: column; gap: 4px;">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp headline_metric(assigns) do
    ~H"""
    <div style="display: flex; align-items: baseline; gap: 8px;">
      <span style={[
        "font-size: 22px; font-weight: 600; letter-spacing: -0.02em;",
        "color: var(--ink); font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </span>
      <span class="ident" style="font-size: 11px; color: var(--ink-3);">
        {@label}
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: "var(--ink)"

  defp metric_row(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">
      <span style="font-size: 12px; color: var(--ink-3);">{@label}</span>
      <span style={[
        "font-size: 13px; font-weight: 600; color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  # --- Formatters --------------------------------------------------------

  defp format_days(nil), do: "—"
  defp format_days(0), do: gettext("today")
  defp format_days(1), do: gettext("1 day")
  defp format_days(n) when is_integer(n), do: gettext("%{n} days", n: n)
  defp format_days(_), do: "—"

  defp format_duration(nil), do: "—"
  defp format_duration(0), do: "—"

  defp format_duration(minutes) when is_integer(minutes) and minutes < 60 do
    "#{minutes}m"
  end

  defp format_duration(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    rem_min = rem(minutes, 60)
    if rem_min == 0, do: "#{hours}h", else: "#{hours}h #{rem_min}m"
  end

  defp format_duration(_), do: "—"

  defp format_relative(nil), do: "—"

  defp format_relative(%DateTime{} = dt) do
    relative_string(DateTime.diff(DateTime.utc_now(), dt, :second))
  end

  defp format_relative(%NaiveDateTime{} = dt) do
    relative_string(NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :second))
  end

  defp format_relative(_), do: "—"

  defp relative_string(seconds) when seconds < 60, do: gettext("just now")
  defp relative_string(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp relative_string(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h ago"
  defp relative_string(seconds), do: "#{div(seconds, 86_400)}d ago"
end
