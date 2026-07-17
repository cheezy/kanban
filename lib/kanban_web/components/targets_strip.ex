defmodule KanbanWeb.TargetsStrip do
  @moduledoc """
  Horizontal strip of delivery-target cards displayed above the boards
  index content. Each card shows the target name, its `target_date`, a
  read-time status badge, and a single completed/total child-task
  fraction (`"12/20 (60%)"`) with a thin filled progress bar. Inside the
  card the values are grouped into clusters (name | dates | badge |
  progress) separated by pill-scale 1px `var(--line)` dividers — the same
  divider treatment the strip header uses, sized down to the card row.

  The strip is a sibling of `KanbanWeb.GoalsStrip` and mirrors its
  structure and token vocabulary: it uses ONLY Stride custom properties
  (`var(--surface)`, `var(--surface-2)`, `var(--ink)`, `var(--ink-3)`,
  `var(--line)`, `var(--st-*)`, `var(--font-mono)`) — no daisyUI classes
  and no hardcoded colors — and all text flows through `gettext/1`.

  Like `goals_strip`, an empty list renders nothing at all
  (`def targets_strip(%{targets: []} = assigns), do: ~H""`), so a
  workspace with no targets shows no empty band above the boards grid.

  The strip carries no "New Target" affordance of its own — the single
  create entry point lives in the always-visible boards index header
  actions (`board_live/index.html.heex`), so it is reachable whether or
  not the workspace has any targets and never appears twice.

  ## Progress

  Progress is a SINGLE fraction of completed child tasks summed across all
  of a target's member goals — rendered as `"N/M (P%)"` text plus a thin
  filled bar (a `var(--surface-2)` track with a status-colored fill sized
  by `width: <P>%`). It is deliberately NOT the segmented five-bucket flow
  bar used by the goals strip.

  ## Status badge palette

  Each status maps to one dark-mode-safe `--st-*` token pair — the badge
  uses `background: var(--st-X-soft); color: var(--st-X)`, and the same
  `var(--st-X)` colors the card border and the progress-bar fill:

    * `:complete` → `--st-done`    (green) — label "Complete"
    * `:on_track` → `--st-ready`   (blue)  — label "On-track"
    * `:at_risk`  → `--st-doing`   (amber) — label "At-risk"
    * `:missed`   → `--st-blocked` (red)   — label "Missed"

  ## Entry shape

  Each entry is a `Kanban.Targets.target_summary/0` map:

      %{
        target: %Kanban.Targets.DeliveryTarget{},
        status: :complete | :on_track | :at_risk | :missed,
        completed: non_neg_integer(),
        total: non_neg_integer(),
        percentage: 0..100,
        estimated_completion_date: Date.t() | nil
      }

  `:estimated_completion_date` is optional and renders a second mono date
  ("Est. Mar 3, 2027") next to the target date when present; `nil` (or a
  missing key) renders nothing — no placeholder, no layout shift, and no
  dangling divider (the cluster dividers are unconditional and never sit
  adjacent to the optional estimate). The estimate is de-emphasized
  relative to the fixed target date (italic, reduced opacity) so the
  committed date stays visually primary.
  """
  use KanbanWeb, :html

  @doc """
  Renders the targets strip.

  ## Attrs

    * `targets` — list of `Kanban.Targets.target_summary/0` maps. Required.
      An empty list renders nothing.
  """
  attr :targets, :list, required: true

  def targets_strip(%{targets: []} = assigns) do
    ~H""
  end

  def targets_strip(assigns) do
    assigns = assign(assigns, :count, length(assigns.targets))

    ~H"""
    <div style={[
      "padding: 10px 22px 12px;",
      "border-bottom: 1px solid var(--line);",
      "background: var(--surface-2);",
      "display: flex; align-items: center; gap: 10px;"
    ]}>
      <div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0;">
        <.icon name="hero-calendar" class="w-2.5 h-2.5" />
        <span class="ucase" style="font-size: 10px;">{gettext("Targets")}</span>
        <span class="ident" style="font-size: 10.5px;">{@count}</span>
      </div>

      <div style="width: 1px; height: 18px; background: var(--line);"></div>

      <div style="display: flex; gap: 8px; flex-wrap: wrap; flex: 1; min-width: 0;">
        <.target_card :for={entry <- @targets} entry={entry} />
      </div>
    </div>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :entry, :map, required: true

  defp target_card(assigns) do
    {token, label} = status_badge(assigns.entry.status)

    assigns =
      assigns
      |> assign(:token, token)
      |> assign(:label, label)
      |> assign(:estimated_date, Map.get(assigns.entry, :estimated_completion_date))

    ~H"""
    <.link navigate={~p"/targets/#{@entry.target.id}"} style={card_style(@token)} data-target-card>
      <span style="font-size: 12px; font-weight: 500; color: var(--ink);">
        {@entry.target.name}
      </span>

      <span style={divider_style()} data-pill-divider aria-hidden="true"></span>

      <span style="font-size: 10.5px; color: var(--ink-3); font-family: var(--font-mono);">
        {format_date(@entry.target.target_date)}
      </span>
      <span
        :if={@estimated_date}
        style="font-size: 10.5px; color: var(--ink-3); font-family: var(--font-mono); font-style: italic; opacity: 0.75;"
        title={gettext("Estimated completion")}
        data-estimated-date
      >
        {gettext("Est. %{date}", date: format_date(@estimated_date))}
      </span>

      <span style={divider_style()} data-pill-divider aria-hidden="true"></span>

      <span style={badge_style(@token)}>{@label}</span>

      <span style={divider_style()} data-pill-divider aria-hidden="true"></span>

      <span style="font-size: 11px; font-family: var(--font-mono); color: var(--ink-3);">
        {@entry.completed}/{@entry.total} ({@entry.percentage}%)
      </span>

      <div style="width: 54px; height: 4px; border-radius: 2px; background: var(--surface-2); overflow: hidden;">
        <div style={"height: 100%; border-radius: 2px; width: #{@entry.percentage}%; background: var(--st-#{@token});"}>
        </div>
      </div>
    </.link>
    """
  end

  # --- Style / mapping helpers --------------------------------------------

  # Card border + left stripe use the target's status token, mirroring the
  # goal-pill style but sourced from a dark-mode-safe --st-* token.
  defp card_style(token) do
    [
      "display: inline-flex; align-items: center; gap: 8px;",
      "padding: 5px 10px 5px 8px;",
      "background: var(--surface);",
      "border: 1px solid var(--st-#{token});",
      "border-left: 3px solid var(--st-#{token});",
      "border-radius: 5px;",
      "text-decoration: none;"
    ]
  end

  defp badge_style(token) do
    [
      "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
      "background: var(--st-#{token}-soft); color: var(--st-#{token});",
      "font-family: var(--font-mono); font-weight: 600;"
    ]
  end

  # Pill-scale variant of the strip header's 1px var(--line) divider
  # (targets_strip/1 above), sized down to fit inside the card row. Placed
  # between the value clusters (name | dates | badge | progress) so each
  # reads as a distinct unit.
  defp divider_style do
    "width: 1px; height: 12px; background: var(--line); flex-shrink: 0;"
  end

  # atom -> {--st-* token stem, translated label}. See the moduledoc palette.
  defp status_badge(:complete), do: {"done", gettext("Complete")}
  defp status_badge(:on_track), do: {"ready", gettext("On-track")}
  defp status_badge(:at_risk), do: {"doing", gettext("At-risk")}
  defp status_badge(:missed), do: {"blocked", gettext("Missed")}

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")
end
