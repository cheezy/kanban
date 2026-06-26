defmodule KanbanWeb.ArchiveStatsStrip do
  @moduledoc """
  2-cell stats strip rendered above the filter chips on the Archive
  view at `/boards/:id/archive`.

  Reads from a `Kanban.Archives.archive_stats/1` map and surfaces two
  per-bucket counters: Total / Completed. Same uppercase label, large
  tabular-numerics value, and soft caption design, using gettext +
  theme tokens.

  Purely presentational. The LiveView owns the stats query.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskTokens

  @doc """
  Renders the stats strip.

  ## Attrs

    * `stats` — required map matching the `Kanban.Archives.archive_stats/1`
      return shape: `%{total, completed}`.
  """
  attr :stats, :map, required: true

  def archive_stats_strip(assigns) do
    ~H"""
    <dl
      data-archive-stats-strip
      style={[
        "display: grid; grid-template-columns: repeat(2, max-content); width: fit-content;",
        "margin: 0; padding: 0;",
        "background: var(--surface);",
        "border: 1px solid var(--line); border-radius: 8px; overflow: hidden;"
      ]}
    >
      <.cell
        marker="total"
        label={gettext("Total archived")}
        value={Integer.to_string(@stats.total)}
        caption={gettext("across the workspace")}
        tone="var(--ink)"
        border_left={false}
      />
      <.cell
        marker="completed"
        label={gettext("Completed")}
        value={Integer.to_string(@stats.completed)}
        caption={gettext("reached Done before archive")}
        tone={TaskTokens.archive_reason_ink(:completed)}
        border_left={true}
      />
    </dl>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :caption, :string, required: true
  attr :tone, :string, required: true
  attr :border_left, :boolean, required: true

  defp cell(assigns) do
    ~H"""
    <div
      data-archive-stats-cell={@marker}
      style={[
        "padding: 14px 18px;",
        if(@border_left, do: "border-left: 1px solid var(--line);", else: "")
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
        "margin: 4px 0 2px;",
        "font-size: 24px; font-weight: 600; letter-spacing: -0.025em;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
      <p style={[
        "margin: 0;",
        "font-size: 11.5px; color: var(--ink-3);",
        "text-wrap: pretty;"
      ]}>
        {@caption}
      </p>
    </div>
    """
  end
end
