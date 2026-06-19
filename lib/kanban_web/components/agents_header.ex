defmodule KanbanWeb.AgentsHeader do
  @moduledoc """
  Header band that sits above the two-column body of the Agents view.

  Renders an H1 title, a subtitle with a pluralized 24-hour event count,
  and four right-aligned KV cards (Claimed today, Completed today,
  Approved today, Cycle time · avg). Stat tones reuse the task-status
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
            label={gettext("Cycle time · avg")}
            value={format_cycle(@stats.avg_cycle_minutes)}
            tone="var(--ink)"
          />
        </dl>
      </div>

      <dl
        data-agents-fleet-health
        style={[
          "display: flex; align-items: stretch; flex-wrap: wrap; gap: 10px;",
          "margin: 0; padding: 0;"
        ]}
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
          marker="stuck"
          label={gettext("Stuck")}
          value={@fleet_health.stuck}
          tone="var(--st-blocked)"
          soft="var(--st-blocked-soft)"
        />
        <.health_stat
          marker="idle"
          label={gettext("Idle")}
          value={@fleet_health.idle}
          tone="var(--stride-orange-ink)"
          soft="var(--stride-orange-soft)"
        />
      </dl>
    </header>
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
end
