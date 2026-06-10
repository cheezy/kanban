defmodule KanbanWeb.MetricsKpiStrip do
  @moduledoc """
  4-cell KPI strip rendered at the top of the workspace `/metrics` page.

  Consumes the map returned by `Kanban.Metrics.workspace_kpis/1`:

      %{
        cycle_time_median_minutes: integer,  cycle_time_delta_pct: float,
        lead_time_p75_minutes: integer,      lead_time_delta_pct: float,
        throughput_per_day: float,           throughput_delta_pct: float,
        review_wait_minutes: integer,        review_wait_delta_pct: float
      }

  Each cell shows the metric label (uppercase), the formatted value
  (tabular-numerics 24px), the delta percentage with tone (green when the
  delta is in the *good* direction for that metric — `down` for waits,
  `up` for throughput), and a soft sub label.

  Mirrors the design source at
  `design_handoff_stride/design_source/screens/extras.jsx` lines 764-785.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Duration

  @doc """
  Renders the KPI strip.

  ## Attrs

    * `kpis` — required map matching the `Kanban.Metrics.workspace_kpis/1`
      return shape.
  """
  attr :kpis, :map, required: true

  def kpi_strip(assigns) do
    ~H"""
    <dl
      data-metrics-kpi-strip
      class="grid grid-cols-2 md:grid-cols-4 m-0 p-0 overflow-hidden"
      style={[
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px;"
      ]}
    >
      <.cell
        marker="cycle-time"
        label={gettext("Cycle time · median")}
        value={Duration.format_minutes(@kpis.cycle_time_median_minutes, pad_remainder: true)}
        delta_pct={@kpis.cycle_time_delta_pct}
        delta_direction={:down}
        sub={gettext("vs prev 14d")}
        border_right={true}
      />
      <.cell
        marker="lead-time"
        label={gettext("Lead time · p75")}
        value={Duration.format_minutes(@kpis.lead_time_p75_minutes, pad_remainder: true)}
        delta_pct={@kpis.lead_time_delta_pct}
        delta_direction={:down}
        sub={gettext("idea → done")}
        border_right={true}
      />
      <.cell
        marker="throughput"
        label={gettext("Throughput")}
        value={format_throughput(@kpis.throughput_per_day)}
        delta_pct={@kpis.throughput_delta_pct}
        delta_direction={:up}
        sub={gettext("vs prev 14d")}
        border_right={true}
      />
      <.cell
        marker="review-wait"
        label={gettext("Wait time · Review")}
        value={Duration.format_minutes(@kpis.review_wait_minutes, pad_remainder: true)}
        delta_pct={@kpis.review_wait_delta_pct}
        delta_direction={:down}
        sub={gettext("human response avg")}
        border_right={false}
      />
    </dl>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta_pct, :float, required: true
  attr :delta_direction, :atom, required: true, values: [:up, :down]
  attr :sub, :string, required: true
  attr :border_right, :boolean, required: true

  defp cell(assigns) do
    assigns = assign(assigns, :tone, delta_tone(assigns.delta_pct, assigns.delta_direction))

    ~H"""
    <div
      data-metrics-kpi-cell={@marker}
      style={[
        "padding: 14px 18px;",
        if(@border_right, do: "border-right: 1px solid var(--line);", else: "")
      ]}
    >
      <dt style={[
        "margin: 0;",
        "font-size: 9.5px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 4px 0 0;",
        "display: flex; align-items: baseline; gap: 8px;"
      ]}>
        <span
          data-metrics-kpi-value
          style={[
            "font-size: 24px; font-weight: 600;",
            "letter-spacing: -0.025em;",
            "color: var(--ink);",
            "font-variant-numeric: tabular-nums;"
          ]}
        >
          {@value}
        </span>
        <span
          data-metrics-kpi-delta
          style={[
            "font-size: 11px;",
            "font-family: var(--font-mono);",
            "color: #{@tone};"
          ]}
        >
          {format_delta(@delta_pct)}
        </span>
      </dd>
      <p
        data-metrics-kpi-sub
        style={[
          "margin: 2px 0 0;",
          "font-size: 11px; color: var(--ink-3);"
        ]}
      >
        {@sub}
      </p>
    </div>
    """
  end

  # --- Formatters ----------------------------------------------------------

  defp format_throughput(0), do: "0 / day"
  defp format_throughput(+0.0), do: "0 / day"

  defp format_throughput(per_day) when is_float(per_day) do
    rounded = Float.round(per_day, 1)
    "#{rounded} / day"
  end

  defp format_throughput(per_day) when is_integer(per_day), do: "#{per_day} / day"

  defp format_delta(+0.0), do: "—"

  defp format_delta(pct) when is_float(pct) do
    sign = if pct > 0, do: "+", else: ""
    "#{sign}#{Float.round(pct, 1)}%"
  end

  # --- Tone derivation -----------------------------------------------------

  # delta is "good" when its sign matches the desired direction.
  # `:down` direction → negative delta is good (e.g. cycle time dropping).
  # `:up` direction   → positive delta is good (e.g. throughput rising).
  defp delta_tone(+0.0, _), do: "var(--ink-3)"
  defp delta_tone(pct, :down) when pct < 0.0, do: "var(--st-done)"
  defp delta_tone(pct, :down) when pct > 0.0, do: "var(--st-blocked)"
  defp delta_tone(pct, :up) when pct > 0.0, do: "var(--st-done)"
  defp delta_tone(pct, :up) when pct < 0.0, do: "var(--st-blocked)"
  defp delta_tone(_, _), do: "var(--ink-3)"
end
