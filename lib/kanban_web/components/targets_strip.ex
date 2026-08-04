defmodule KanbanWeb.TargetsStrip do
  @moduledoc """
  Horizontal strip of delivery-target cards displayed above the boards
  index content. Each card shows the target name, its `target_date`
  (labeled "Due."), a read-time status badge, and a single completed/total child-task
  fraction (`"12/20 (60%)"`) with a thin filled progress bar. Inside the
  card the values are grouped into clusters (name | dates | badge |
  progress) separated by pill-scale 1px `var(--ink-4)` dividers —
  `--ink-4` is the app.css separator token, chosen after the hairline
  `var(--line)` proved invisible at pill scale (D163).

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

  The target date is labeled "Due." ("Due. Dec 31, 2026") so it reads as
  a distinct value, parallel to the "Est." estimate label.

  `:estimated_completion_date` is optional and renders a second mono date
  ("Est. Mar 3, 2027") after the target date when present, preceded by its
  own divider so the two dates read as separate values; `nil` (or a
  missing key) renders nothing — no placeholder, no layout shift, and no
  dangling divider (the date separator shares the estimate span's `:if`,
  while the three cluster dividers are unconditional). The estimate is
  de-emphasized relative to the fixed target date (italic, plus its "Est."
  label) so the committed date stays visually primary. That de-emphasis is
  deliberately not carried by opacity — see `estimated_date_style/1`.
  """
  use KanbanWeb, :html

  alias Kanban.Targets.Status

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
      |> then(
        &assign(&1, :slipped?, Status.slipped?(&1.estimated_date, &1.entry.target.target_date))
      )

    ~H"""
    <.link navigate={~p"/targets/#{@entry.target.id}"} style={card_style(@token)} data-target-card>
      <span style="font-size: 12px; font-weight: 500; color: var(--ink); flex-shrink: 0; white-space: nowrap;">
        {@entry.target.name}
      </span>

      <span style={divider_style()} data-pill-divider aria-hidden="true"></span>

      <span style="font-size: 10.5px; color: var(--ink-3); font-family: var(--font-mono); white-space: nowrap;">
        {gettext("Due. %{date}", date: format_date(@entry.target.target_date))}
      </span>
      <span :if={@estimated_date} style={divider_style()} data-pill-divider aria-hidden="true"></span>
      <span
        :if={@estimated_date}
        style={estimated_date_style(@slipped?)}
        title={estimated_date_title(@slipped?, @entry.target.target_date)}
        data-estimated-date
        data-estimate-slipped={@slipped?}
      >
        {gettext("Est. %{date}", date: format_date(@estimated_date))}
      </span>
      <span :if={@slipped?} style={slip_chip_style()} data-estimate-slip-chip>
        {gettext("Slipped")}
        <span class="sr-only">
          {gettext("Estimated completion — after the %{target_date} target",
            target_date: format_date(@entry.target.target_date)
          )}
        </span>
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
  #
  # The pill is a nested inline-flex item of the strip's `flex: 1; min-width: 0`
  # card row, so the row caps the space it offers each pill. flex-shrink 0 +
  # nowrap alone did not stop a long name from squeezing out the first divider
  # (Safari caps the pill's computed basis to the row's width, D164 follow-up),
  # so min-width: max-content pins the pill to its full content width. The name
  # and every divider stay visible and the whole pill wraps to the next row via
  # the row's flex-wrap instead of the title/divider being clipped.
  defp card_style(token) do
    [
      "display: inline-flex; align-items: center; gap: 10px;",
      "padding: 5px 10px 5px 8px;",
      "background: var(--surface);",
      "border: 1px solid var(--st-#{token});",
      "border-left: 3px solid var(--st-#{token});",
      "border-radius: 5px;",
      "text-decoration: none;",
      "flex-shrink: 0; white-space: nowrap; min-width: max-content;"
    ]
  end

  defp badge_style(token) do
    [
      "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
      "background: var(--st-#{token}-soft); color: var(--st-#{token});",
      "font-family: var(--font-mono); font-weight: 600;"
    ]
  end

  # Pill-scale divider between the value clusters (name | dates | badge |
  # progress) and, conditionally, between the two dates. Uses var(--ink-4) —
  # the token app.css earmarks for separators, held to the 3:1 graphical
  # contrast floor in both themes — because the hairline var(--line) proved
  # invisible at pill scale (D163). The margins add breathing room on top of
  # the card's flex gap so the clusters read as separate groups.
  defp divider_style do
    "width: 1px; height: 15px; background: var(--ink-4); flex-shrink: 0; margin: 0 2px;"
  end

  # atom -> {--st-* token stem, translated label}. See the moduledoc palette.
  defp status_badge(:complete), do: {"done", gettext("Complete")}
  defp status_badge(:on_track), do: {"ready", gettext("On-track")}
  defp status_badge(:at_risk), do: {"doing", gettext("At-risk")}
  defp status_badge(:missed), do: {"blocked", gettext("Missed")}

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  # A slipping estimate stops being de-emphasized: it is the reason the badge
  # beside it reads At-risk. It takes --ink-2 (a measured text-on-surface pair)
  # at full opacity rather than a status token as body text — the contrast gate
  # measures --st-* only against its own -soft fill, so a status token used as
  # text on --surface would be an unvalidated pair. The amber lives in the
  # adjacent chip instead, where the pair IS measured.
  defp estimated_date_style(true) do
    "font-size: 10.5px; color: var(--ink-2); font-family: var(--font-mono); font-style: italic; font-weight: 600;"
  end

  # De-emphasized by italic and the "Est." label, NOT by opacity (D213). An
  # opacity here composites against --surface at the usage site, which the
  # contrast gate cannot see: it measures --ink-3 on --surface (5.51:1 light)
  # and passes the pair, while the rendered pixels sat at 3.26:1 — under the
  # 4.5:1 floor this token carries for 10.5px text. --ink-3 at full opacity
  # clears it in both themes (5.51:1 light, 8.14:1 dark) and stays quieter
  # than the target name, which is --ink.
  defp estimated_date_style(false) do
    "font-size: 10.5px; color: var(--ink-3); font-family: var(--font-mono); font-style: italic;"
  end

  # The slip marker. Colour alone must not carry the meaning, so the state is
  # spelled out in a translated label; the soft fill + --line border follow the
  # chip-delineation rule in docs/dark-mode-contract.md, and
  # --st-doing on --st-doing-soft is a gate-measured pair (9.09:1).
  defp slip_chip_style do
    [
      "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
      "background: var(--st-doing-soft); color: var(--st-doing);",
      "border: 1px solid var(--line);",
      "font-family: var(--font-mono); font-weight: 600; white-space: nowrap;"
    ]
  end

  # The title is what makes the due-vs-estimate relationship legible rather than
  # something the reader has to infer from two dates sitting next to each other.
  defp estimated_date_title(true, %Date{} = target_date) do
    gettext("Estimated completion — after the %{target_date} target",
      target_date: format_date(target_date)
    )
  end

  defp estimated_date_title(false, _target_date), do: gettext("Estimated completion")
end
