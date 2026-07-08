defmodule KanbanWeb.DeliveryHealthBand do
  @moduledoc """
  Top-of-page band on the Agents view that answers "is delivery on track?"
  at a glance by bucketing the scoped delivery targets by their read-time
  status.

  It renders one stat tile per target status — On-track, At-risk, Missed,
  Complete — each showing the number of targets in that bucket and the
  soonest `target_date` among them. The band binds the output of
  `Kanban.Targets.DeliveryRollup.build/2` (the `:targets` list); it runs no
  queries of its own, so every count already reflects only targets the caller
  can access.

  ## Tokens

  Like `KanbanWeb.TargetsStrip`, the band uses ONLY Stride custom properties
  (`var(--surface)`, `var(--ink)`, `var(--ink-3)`, `var(--line)`, `var(--st-*)`)
  — no daisyUI classes and no hardcoded colors — so it stays legible in both
  light and dark mode. Each status maps to one dark-mode-safe `--st-*` token:

    * `:on_track` → `--st-ready`   (blue)  — label "On-track"
    * `:at_risk`  → `--st-doing`   (amber) — label "At-risk"
    * `:missed`   → `--st-blocked` (red)   — label "Missed"
    * `:complete` → `--st-done`    (green) — label "Complete"

  All copy flows through `gettext/1`. An empty target set renders the band's
  heading plus an empty-state line rather than four zero buckets.
  """
  use KanbanWeb, :html

  # The status buckets in display order. Each is `{status, marker, token}`;
  # the human label comes from `status_label/1` so it is translated at render.
  @buckets [
    {:on_track, "on-track", "ready"},
    {:at_risk, "at-risk", "doing"},
    {:missed, "missed", "blocked"},
    {:complete, "complete", "done"}
  ]

  @doc """
  Renders the delivery-health band.

  ## Attrs

    * `targets` — the `:targets` list from `Kanban.Targets.DeliveryRollup.build/2`
      (each entry a map with `:status` and `:target`). Required; an empty list
      renders the empty state.
  """
  attr :targets, :list, required: true

  def delivery_health_band(assigns) do
    grouped = Enum.group_by(assigns.targets, & &1.status)
    assigns = assign(assigns, :stats, Enum.map(@buckets, &bucket_stat(&1, grouped)))

    ~H"""
    <section
      data-delivery-health-band
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 12px;",
        "padding: 12px 24px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <h2 style={[
        "margin: 0;",
        "font-size: 11px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {gettext("Delivery health")}
      </h2>

      <dl
        :if={@targets != []}
        data-delivery-health-stats
        style={[
          "display: flex; align-items: flex-start; flex-wrap: wrap; gap: 18px;",
          "margin: 0; padding: 0;"
        ]}
      >
        <.status_stat :for={stat <- @stats} stat={stat} />
      </dl>

      <p
        :if={@targets == []}
        data-delivery-health-empty
        style={[
          "margin: 0;",
          "font-size: 12px; font-style: italic;",
          "color: var(--ink-3);"
        ]}
      >
        {gettext("No delivery targets yet.")}
      </p>
    </section>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :stat, :map, required: true

  # One status bucket: a translated label, the target count toned by the
  # status color, and the soonest target date in the bucket (or an em dash).
  defp status_stat(assigns) do
    ~H"""
    <div
      data-delivery-health-stat={@stat.marker}
      style="display: flex; flex-direction: column; gap: 3px; min-width: 116px;"
    >
      <dt style={[
        "margin: 0;",
        "font-size: 11px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@stat.label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 24px; font-weight: 600;",
        "color: var(--st-#{@stat.token});",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@stat.count}
      </dd>
      <span
        data-delivery-health-soonest
        title={gettext("Soonest target date")}
        style={[
          "font-size: 10.5px; color: var(--ink-3);",
          "font-family: var(--font-mono);"
        ]}
      >
        {soonest_label(@stat.soonest)}
      </span>
    </div>
    """
  end

  # --- Derivation / mapping helpers ----------------------------------------

  # Builds one stat map for a bucket from the status-grouped targets.
  defp bucket_stat({status, marker, token}, grouped) do
    entries = Map.get(grouped, status, [])

    %{
      marker: marker,
      token: token,
      label: status_label(status),
      count: length(entries),
      soonest: soonest_date(entries)
    }
  end

  # The soonest (earliest) target_date across a bucket's entries, or nil when
  # the bucket is empty.
  defp soonest_date([]), do: nil

  defp soonest_date(entries) do
    entries |> Enum.map(& &1.target.target_date) |> Enum.min(Date)
  end

  defp soonest_label(nil), do: "—"
  defp soonest_label(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  # status atom -> translated label. Mirrors KanbanWeb.TargetsStrip's palette.
  defp status_label(:on_track), do: gettext("On-track")
  defp status_label(:at_risk), do: gettext("At-risk")
  defp status_label(:missed), do: gettext("Missed")
  defp status_label(:complete), do: gettext("Complete")
end
