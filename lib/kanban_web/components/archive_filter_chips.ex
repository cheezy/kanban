defmodule KanbanWeb.ArchiveFilterChips do
  @moduledoc """
  Filter chip row for the Archive view at `/boards/:id/archive`.

  Renders the "All" chip followed by one chip per archive reason
  (Completed / Cancelled / Won't do / Duplicate / Deferred) with the
  per-bucket counts from `Kanban.Archives.archive_stats/1`. A divider
  separates these from three visually disabled placeholder chips
  (Goal / Assignee / Date range) that map to v1-out-of-scope filters.

  Active chips emit a `phx-click` event with `phx-value-reason` set to
  the string form of the reason atom (e.g. `"completed"`) or `"all"`.
  The parent LiveView is responsible for coercing the string back to
  an atom — use `String.to_existing_atom/1`, never `String.to_atom/1`.

  Mirrors the `FilterChip` block in
  `design_handoff_stride/design_source/screens/archive.jsx` lines
  280-300.
  """
  use KanbanWeb, :html

  @reasons [
    {:completed, "completed", "done"},
    {:cancelled, "cancelled", "blocked"},
    {:wontdo, "wontdo", nil},
    {:duplicate, "duplicate", nil},
    {:deferred, "deferred", "review"}
  ]

  @doc """
  Renders the filter chip row.

  ## Attrs

    * `counts` — map keyed by `:all` and each reason atom
      (`:completed`, `:cancelled`, `:wontdo`, `:duplicate`, `:deferred`).
      Missing keys render as `0`.
    * `active` — currently active filter, one of `:all` or any reason
      atom. Drives the inverted (ink-bg / white-fg) chip styling.
    * `on_filter_change` — required `phx-click` event name. Fired with
      `phx-value-reason` set to the string form of the chip's reason
      (e.g. `"all"`, `"completed"`).
  """
  attr :counts, :map, required: true
  attr :active, :atom, required: true
  attr :on_filter_change, :string, required: true

  def archive_filter_chips(assigns) do
    ~H"""
    <div
      data-archive-filter-chips
      style={[
        "display: flex; align-items: center; gap: 6px;",
        "flex-wrap: wrap;",
        "padding: 0 28px 12px;"
      ]}
    >
      <.chip
        marker="all"
        reason_value="all"
        label={gettext("All")}
        count={Map.get(@counts, :all, 0)}
        show_count={false}
        active={@active == :all}
        tone={nil}
        on_filter_change={@on_filter_change}
      />

      <.chip
        :for={{reason, value, tone} <- reasons()}
        marker={value}
        reason_value={value}
        label={reason_label(reason)}
        count={Map.get(@counts, reason, 0)}
        show_count={true}
        active={@active == reason}
        tone={tone}
        on_filter_change={@on_filter_change}
      />

      <span
        aria-hidden="true"
        data-archive-filter-divider
        style="width: 1px; height: 18px; background: var(--line); margin: 0 4px;"
      />

      <.placeholder_chip marker="goal" label={gettext("Goal")} icon="hero-flag" />
      <.placeholder_chip marker="assignee" label={gettext("Assignee")} icon="hero-user" />
      <.placeholder_chip
        marker="date-range"
        label={gettext("Date range")}
        icon="hero-clock"
      />
    </div>
    """
  end

  # --- Active chip ---------------------------------------------------------

  attr :marker, :string, required: true
  attr :reason_value, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :show_count, :boolean, required: true
  attr :active, :boolean, required: true
  attr :tone, :any, default: nil
  attr :on_filter_change, :string, required: true

  defp chip(assigns) do
    palette = chip_palette(assigns.active, assigns.tone)
    assigns = assign(assigns, :palette, palette)

    ~H"""
    <button
      type="button"
      data-archive-filter-chip={@marker}
      aria-pressed={if @active, do: "true", else: "false"}
      phx-click={@on_filter_change}
      phx-value-reason={@reason_value}
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 3px 8px; border-radius: 4px;",
        "font: inherit; font-size: 11.5px; font-weight: 500;",
        "border: 1px solid #{@palette.border};",
        "background: #{@palette.bg};",
        "color: #{@palette.fg};",
        "cursor: pointer;"
      ]}
    >
      <span>{@label}</span>
      <span :if={@show_count} style="font-variant-numeric: tabular-nums;">
        · {@count}
      </span>
    </button>
    """
  end

  # --- Decorative placeholder chip ----------------------------------------

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp placeholder_chip(assigns) do
    ~H"""
    <span
      data-archive-filter-chip-placeholder={@marker}
      aria-disabled="true"
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 3px 8px; border-radius: 4px;",
        "font-size: 11.5px; font-weight: 500;",
        "border: 1px solid var(--line);",
        "background: var(--surface);",
        "color: var(--ink-3);",
        "cursor: not-allowed; opacity: 0.7;"
      ]}
    >
      <.icon name={@icon} class="w-2.5 h-2.5" />
      <span>{@label}</span>
    </span>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp reasons, do: @reasons

  defp reason_label(:completed), do: gettext("Completed")
  defp reason_label(:cancelled), do: gettext("Cancelled")
  defp reason_label(:wontdo), do: gettext("Won't do")
  defp reason_label(:duplicate), do: gettext("Duplicate")
  defp reason_label(:deferred), do: gettext("Deferred")

  # Returns a %{bg, fg, border} map. Active chips invert to ink-bg white-fg.
  defp chip_palette(true, _tone) do
    %{bg: "var(--ink)", fg: "white", border: "var(--ink)"}
  end

  defp chip_palette(false, "done") do
    %{
      bg: "var(--st-done-soft)",
      fg: "var(--st-done)",
      border: "transparent"
    }
  end

  defp chip_palette(false, "blocked") do
    %{
      bg: "var(--st-blocked-soft)",
      fg: "var(--st-blocked)",
      border: "transparent"
    }
  end

  defp chip_palette(false, "review") do
    %{
      bg: "var(--st-review-soft)",
      fg: "var(--st-review)",
      border: "transparent"
    }
  end

  defp chip_palette(false, _) do
    %{
      bg: "var(--surface)",
      fg: "var(--ink-2)",
      border: "var(--line)"
    }
  end
end
