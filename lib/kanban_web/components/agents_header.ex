defmodule KanbanWeb.AgentsHeader do
  @moduledoc """
  Header band that sits above the two-column body of the Agents view.

  Renders an H1 title, a subtitle with a pluralized 24-hour event count,
  and four right-aligned KV cards (Claimed today, Completed today,
  Approved today, Cycle time · today). Stat tones reuse the task-status
  palette: doing for claims, doing for completions of work in flight,
  review for completed-today, done for approved, and a neutral ink for
  the cycle-time card.

  This component is purely presentational. The caller assembles `:stats`
  (the map shape returned by `Kanban.Agents.header_stats/1`),
  `:fleet_health` (the map shape returned by `Kanban.Agents.fleet_health/1`),
  and `:event_count_24h` and passes them in via attrs.

  Below the title and daily stat cards, a fleet-health rollup shows the
  working / waiting / stuck / idle agent counts. Stuck and idle are rendered
  as emphasized soft-background pills (stuck in the blocked/danger palette,
  idle in the brand-orange attention palette) so ops can spot problems and
  spare capacity at a glance; working and waiting stay as plain stat cards.
  """
  use KanbanWeb, :html

  @doc """
  Renders the header band.

  ## Attrs

    * `stats` — map with `:claimed_today`, `:completed_today`,
      `:approved_today`, and `:avg_cycle_minutes` keys. Required.
    * `fleet_health` — map with `:working`, `:waiting`, `:stuck`, and
      `:idle` counts (the shape returned by `Kanban.Agents.fleet_health/1`).
      Required.
    * `event_count_24h` — non-negative integer used in the pluralized
      subtitle copy. Required.
  """
  attr :stats, :map, required: true
  attr :fleet_health, :map, required: true
  attr :event_count_24h, :integer, required: true

  def header(assigns) do
    ~H"""
    <header
      data-agents-header
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 14px;",
        "padding: 14px 24px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <div style={[
        "display: flex; align-items: flex-end; justify-content: space-between;",
        "gap: 24px; flex-wrap: wrap;"
      ]}>
        <div style="display: flex; flex-direction: column; gap: 4px; min-width: 0;">
          <h1 style={[
            "margin: 0;",
            "font-size: 18px; font-weight: 600;",
            "letter-spacing: -0.01em;",
            "color: var(--ink);"
          ]}>
            {gettext("Agent activity")}
          </h1>
          <p style={[
            "margin: 0;",
            "font-size: 12px;",
            "color: var(--ink-3);",
            "font-variant-numeric: tabular-nums;"
          ]}>
            {subtitle(@event_count_24h)}
          </p>
        </div>

        <dl
          data-agents-header-stats
          style={[
            "display: flex; align-items: stretch; gap: 18px;",
            "margin: 0; padding: 0;"
          ]}
        >
          <.kv
            marker="claimed-today"
            label={gettext("Claimed today")}
            value={@stats.claimed_today}
            tone="var(--st-doing)"
          />
          <.kv
            marker="completed-today"
            label={gettext("Completed today")}
            value={@stats.completed_today}
            tone="var(--st-review)"
          />
          <.kv
            marker="approved-today"
            label={gettext("Approved today")}
            value={@stats.approved_today}
            tone="var(--st-done)"
          />
          <.kv
            marker="cycle-time"
            label={gettext("Cycle time · today")}
            value={format_cycle(@stats.avg_cycle_minutes)}
            tone="var(--ink)"
          />
        </dl>
      </div>

      <dl
        data-agents-fleet-health
        style={[
          "display: flex; align-items: center; flex-wrap: wrap; gap: 10px;",
          "margin: 0; padding: 0;"
        ]}
      >
        <%!-- Working / Waiting / Idle partition the live agent set and sum to it. --%>
        <div
          data-agents-fleet-health-partition
          style="display: flex; align-items: stretch; flex-wrap: wrap; gap: 10px;"
        >
          <.health_stat
            marker="working"
            label={gettext("Working")}
            value={@fleet_health.working}
            tone="var(--st-doing)"
          />
          <.health_stat
            marker="waiting"
            label={gettext("Waiting")}
            value={@fleet_health.waiting}
            tone="var(--ink-3)"
          />
          <.health_stat
            marker="idle"
            label={gettext("Idle")}
            value={@fleet_health.idle}
            tone="var(--stride-orange-ink)"
            soft="var(--stride-orange-soft)"
          />
        </div>

        <span
          data-agents-fleet-health-divider
          aria-hidden="true"
          style={[
            "align-self: center;",
            "width: 1px; height: 28px;",
            "background: var(--line);"
          ]}
        />

        <%!-- Stuck is a cross-cutting overlay, not part of the partition above:
             a stuck agent is already counted in working or waiting. --%>
        <div
          data-agents-fleet-health-overlay
          style="display: flex; align-items: center; gap: 8px;"
        >
          <span style={[
            "font-size: 10px; font-weight: 600;",
            "text-transform: uppercase; letter-spacing: 0.08em;",
            "color: var(--ink-3);"
          ]}>
            {gettext("of which")}
          </span>
          <.health_stat
            marker="stuck"
            label={gettext("Stuck")}
            value={@fleet_health.stuck}
            tone="var(--st-blocked)"
            soft="var(--st-blocked-soft)"
          />
        </div>
      </dl>
    </header>
    """
  end

  @doc """
  Renders the PM-facing delivery-trends band.

  Sits below the header/live-indicator and above the two-column body. Shows
  throughput counters (today / 7d / 30d), the overall success rate, and the
  average cycle time as stat cards, followed by a compact per-day throughput
  bar strip. Purely presentational — the caller passes the aggregate maps.

  ## Attrs

    * `throughput_and_success` — map with `:completed_today`, `:completed_7d`,
      `:completed_30d`, the matching `:completed_prev_today` /
      `:completed_prev_7d` / `:completed_prev_30d` prior-period counts (used to
      render the per-window delta), and `:success_rate` (the shape returned by
      `Kanban.Agents.throughput_and_success/1`). Required.
    * `throughput_trends` — map with `:series` (a list of
      `%{date: Date.t(), count: non_neg_integer()}`) and `:avg_cycle_minutes`
      (the shape returned by `Kanban.Agents.throughput_trends/1`). Required.
  """
  attr :throughput_and_success, :map, required: true
  attr :throughput_trends, :map, required: true

  def pm_trends(assigns) do
    series = assigns.throughput_trends.series

    max_count =
      case Enum.map(series, & &1.count) do
        [] -> 0
        counts -> Enum.max(counts)
      end

    assigns = assign(assigns, :max_count, max_count)

    ~H"""
    <section
      data-agents-pm-trends
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 12px;",
        "padding: 12px 24px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <div style={[
        "display: flex; align-items: flex-start; justify-content: space-between;",
        "gap: 16px; flex-wrap: wrap;"
      ]}>
        <h2 style={[
          "margin: 0;",
          "font-size: 11px; font-weight: 600;",
          "text-transform: uppercase; letter-spacing: 0.08em;",
          "color: var(--ink-3);"
        ]}>
          {gettext("Delivery trends")}
        </h2>

        <dl
          data-agents-pm-trends-stats
          style={[
            "display: flex; align-items: flex-start; flex-wrap: wrap; gap: 18px;",
            "margin: 0; padding: 0;"
          ]}
        >
          <.trend_stat
            marker="throughput-today"
            label={gettext("Completed today")}
            value={@throughput_and_success.completed_today}
            tone="var(--st-done)"
            delta={
              @throughput_and_success.completed_today - @throughput_and_success.completed_prev_today
            }
          />
          <.trend_stat
            marker="throughput-7d"
            label={gettext("Completed · 7d")}
            value={@throughput_and_success.completed_7d}
            tone="var(--st-done)"
            delta={@throughput_and_success.completed_7d - @throughput_and_success.completed_prev_7d}
          />
          <.trend_stat
            marker="throughput-30d"
            label={gettext("Completed · 30d")}
            value={@throughput_and_success.completed_30d}
            tone="var(--st-done)"
            delta={@throughput_and_success.completed_30d - @throughput_and_success.completed_prev_30d}
          />
          <.trend_stat
            marker="success-rate"
            label={gettext("Success rate")}
            value={format_rate(@throughput_and_success.success_rate)}
            tone="var(--st-review)"
          />
        </dl>
      </div>

      <div
        :if={@max_count > 0}
        data-agents-pm-trends-series
        style={[
          "display: flex; align-items: flex-end; gap: 4px;",
          "height: 128px; overflow-x: auto;"
        ]}
      >
        <div
          :for={entry <- @throughput_trends.series}
          data-agents-pm-trends-bar={Date.to_iso8601(entry.date)}
          title={trend_bar_title(entry)}
          style={[
            "display: flex; flex-direction: column; align-items: center; gap: 3px;",
            "min-width: 18px;"
          ]}
        >
          <span style={[
            "font-size: 9px; color: var(--ink-3);",
            "font-variant-numeric: tabular-nums;"
          ]}>
            {entry.count}
          </span>
          <span
            aria-hidden="true"
            style={[
              "width: 14px; border-radius: 3px 3px 0 0;",
              "background: var(--st-done);",
              "height: #{bar_height(entry.count, @max_count)}px;"
            ]}
          />
          <span style={[
            "font-size: 9px; color: var(--ink-3);",
            "font-variant-numeric: tabular-nums;"
          ]}>
            {format_day(entry.date)}
          </span>
        </div>
      </div>

      <p
        :if={@max_count == 0}
        data-agents-pm-trends-empty
        style={[
          "margin: 0;",
          "font-size: 12px; font-style: italic;",
          "color: var(--ink-3);"
        ]}
      >
        {gettext("No completed tasks in this window yet.")}
      </p>
    </section>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, required: true
  attr :delta, :integer, default: nil

  # One PM-trends stat card. Mirrors `kv/1` styling but carries its own
  # `data-agents-pm-trends-stat` marker so it is queryable independently of
  # the header's daily stat cards (which reuse some of the same labels). When
  # `delta` is given, a colored arrow + signed delta versus the prior period
  # is shown beneath the value.
  defp trend_stat(assigns) do
    ~H"""
    <div
      data-agents-pm-trends-stat={@marker}
      style="display: flex; flex-direction: column; gap: 3px; min-width: 104px;"
    >
      <dt style={[
        "margin: 0;",
        "font-size: 11px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 24px; font-weight: 600;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
      <div
        :if={@delta != nil}
        data-agents-pm-trends-delta
        title={gettext("vs the prior period")}
        style={[
          "display: inline-flex; align-items: center; gap: 2px;",
          "font-size: 10px; font-weight: 600;",
          "font-variant-numeric: tabular-nums;",
          "color: #{delta_tone(@delta)};"
        ]}
      >
        <.icon name={delta_icon(@delta)} class="w-3 h-3" />
        <span>{delta_label(@delta)}</span>
      </div>
    </div>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div
      data-agents-header-kv={@marker}
      style="display: flex; flex-direction: column; gap: 2px; min-width: 88px;"
    >
      <dt style={[
        "margin: 0;",
        "font-size: 10px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 18px; font-weight: 600;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, required: true
  attr :soft, :string, default: nil

  # One fleet-health count. When `soft` is given the card renders as an
  # emphasized pill (soft background + matching ink) to draw attention to the
  # stuck and idle counts; otherwise it is a plain stat card like `kv/1`.
  defp health_stat(assigns) do
    ~H"""
    <div
      data-agents-fleet-health-stat={@marker}
      style={[
        "display: flex; flex-direction: column; gap: 2px; min-width: 76px;",
        if(@soft,
          do: "padding: 6px 10px; border-radius: 8px; background: #{@soft};",
          else: ""
        )
      ]}
    >
      <dt style={[
        "margin: 0;",
        "font-size: 10px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: #{if @soft, do: @tone, else: "var(--ink-3)"};"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 18px; font-weight: 600;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp subtitle(count) when is_integer(count) and count >= 0 do
    ngettext(
      "last 24h · %{count} event",
      "last 24h · %{count} events",
      count,
      count: count
    )
  end

  defp format_cycle(nil), do: "—"

  defp format_cycle(minutes) when is_number(minutes) do
    total = round(minutes)

    cond do
      total <= 0 ->
        "—"

      total >= 60 ->
        hours = div(total, 60)
        rem_min = rem(total, 60)
        gettext("%{h}h %{m}m", h: hours, m: rem_min)

      true ->
        gettext("%{m}m", m: total)
    end
  end

  defp format_cycle(_), do: "—"

  # Overall success rate (a 0.0..1.0 float) rendered as a whole-number percent.
  defp format_rate(rate) when is_number(rate), do: gettext("%{pct}%", pct: round(rate * 100))
  defp format_rate(_), do: "—"

  # Compact day-of-month label under each throughput bar.
  defp format_day(%Date{} = date), do: Calendar.strftime(date, "%-d")

  # Hover title for a throughput bar — full month/day and the completion count.
  defp trend_bar_title(%{date: %Date{} = date, count: count}) do
    gettext("%{date}: %{count} completed",
      date: Calendar.strftime(date, "%b %-d"),
      count: count
    )
  end

  # Bar pixel height scaled to the window's busiest day (max 80px). A minimum
  # of 4px keeps non-zero-but-tiny days visible; the series is only rendered
  # when at least one day has activity, so `max` is always positive here.
  defp bar_height(count, max) when is_integer(count) and is_integer(max) and max > 0 do
    max(4, round(count / max * 80))
  end

  # Period-over-period delta presentation: up is the completion (good) tone,
  # down is the blocked/danger tone, and a flat delta is neutral ink.
  defp delta_tone(delta) when delta > 0, do: "var(--st-done)"
  defp delta_tone(delta) when delta < 0, do: "var(--st-blocked)"
  defp delta_tone(_delta), do: "var(--ink-3)"

  defp delta_icon(delta) when delta > 0, do: "hero-arrow-up"
  defp delta_icon(delta) when delta < 0, do: "hero-arrow-down"
  defp delta_icon(_delta), do: "hero-minus"

  # Signed delta label: "+3" for a gain, "0" when flat, "-2" for a decline.
  defp delta_label(delta) when delta > 0, do: "+#{delta}"
  defp delta_label(delta), do: Integer.to_string(delta)
end
