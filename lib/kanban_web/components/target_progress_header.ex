defmodule KanbanWeb.TargetProgressHeader do
  @moduledoc """
  Hero band rendered at the top of the delivery-target drill-down page.

  Mirrors `KanbanWeb.GoalProgressHeader`: an eyebrow row (calendar icon,
  "Target" pill, formatted target date, status badge), the target name as an
  `<h1>`, an optional description blurb, and a progress band that composes
  `KanbanWeb.SegmentedProgressBar` at `:lg` alongside an aggregate percentage,
  an N-of-M complete count, and a per-status KV strip.

  Pure presentation per the W550 pitfall: the aggregate `summary` and `flow`
  are computed by the LiveView (from `Kanban.Targets.get_target_progress/2`)
  and passed in as attrs — the component loads no data itself.

  The status badge label + color vocabulary is duplicated verbatim from
  `KanbanWeb.TargetsStrip` (each component owns its private style helpers in
  this codebase) so the drill-down hero and the boards strip agree:
  Complete / On-track / At-risk / Missed, each keyed to one dark-mode-safe
  `--st-*` token.
  """
  use KanbanWeb, :html

  alias KanbanWeb.SegmentedProgressBar

  @doc """
  Renders the target progress header.

  ## Attrs

    * `summary` — a `Kanban.Targets.target_summary/0` map:
      `%{target: %DeliveryTarget{}, status:, completed:, total:, percentage:}`.
      The percentage is re-derived here from `completed`/`total` (guarding
      `total == 0`) rather than trusting the passed value. Required.
    * `flow` — the aggregate child-status count map driving the segmented bar
      and the per-status KV strip: `%{done, review, doing, ready, backlog,
      total}`. Required.
  """
  attr :summary, :map, required: true
  attr :flow, :map, required: true

  def target_progress_header(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <header
      data-target-progress-header
      class="stride-screen"
      style={[
        "padding: 20px 28px 18px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
        <span style="color: var(--stride-violet); display: inline-flex;">
          <.icon name="hero-calendar" class="w-4 h-4" />
        </span>
        <span style={[
          "display: inline-flex; align-items: center;",
          "padding: 2px 7px; border-radius: 999px;",
          "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
          "font-size: 10.5px; font-weight: 600;"
        ]}>
          {gettext("Target")}
        </span>
        <span :if={@target_date} class="ident" style="font-size: 11.5px; color: var(--ink-2);">
          {@target_date}
        </span>
        <span style={badge_style(@status_token)} data-target-status-badge>{@status_label}</span>
      </div>

      <h1 style={[
        "margin: 0; font-size: 26px; font-weight: 600;",
        "letter-spacing: -0.025em; text-wrap: pretty; color: var(--ink);"
      ]}>
        {@name}
      </h1>

      <p
        :if={@description}
        style={[
          "margin: 6px 0 0; font-size: 13px; color: var(--ink-2);",
          "max-width: 720px; text-wrap: pretty;"
        ]}
      >
        {@description}
      </p>

      <div style="margin-top: 18px; display: flex; align-items: center; gap: 20px; flex-wrap: wrap;">
        <div style="display: flex; flex-direction: column; gap: 6px; min-width: 220px;">
          <div style="display: flex; align-items: baseline; gap: 8px;">
            <span style={[
              "font-size: 26px; font-weight: 600; letter-spacing: -0.025em;",
              "color: var(--ink); font-variant-numeric: tabular-nums;"
            ]}>
              {@pct}%
            </span>
            <span class="ident" style="font-size: 11px; color: var(--ink-3);">
              {gettext("%{done} of %{total} complete", done: @done, total: @total)}
            </span>
          </div>
          <SegmentedProgressBar.segmented_progress
            flow={@flow}
            size={:lg}
            aria_label={gettext("Target progress by child status")}
          />
        </div>

        <div style="display: flex; gap: 18px; flex-wrap: wrap;">
          <.kv :for={{label, count, tone} <- @kv_rows} label={label} count={count} tone={tone} />
        </div>
      </div>
    </header>
    """
  end

  # --- Sub-components ----------------------------------------------------

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :tone, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div>
      <div class="ucase" style="font-size: 9.5px; color: var(--ink-3);">{@label}</div>
      <div style={[
        "font-size: 16px; font-weight: 600; color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@count}
      </div>
    </div>
    """
  end

  # --- Assign derivation -------------------------------------------------

  defp derive_assigns(assigns) do
    summary = assigns.summary

    assigns
    |> assign_target_fields(summary.target)
    |> assign_status(summary.status)
    |> assign_progress(summary)
    |> assign(:kv_rows, kv_rows(assigns.flow))
  end

  defp assign_target_fields(assigns, target) do
    assigns
    |> assign(:name, Map.get(target, :name, ""))
    |> assign(:target_date, format_target_date(Map.get(target, :target_date)))
    |> assign(:description, present_or_nil(Map.get(target, :description)))
  end

  defp assign_status(assigns, status) do
    {token, label} = status_badge(status)

    assigns
    |> assign(:status_token, token)
    |> assign(:status_label, label)
  end

  defp assign_progress(assigns, summary) do
    total = Map.get(summary, :total, 0)
    done = Map.get(summary, :completed, 0)
    pct = if total > 0, do: round(done / total * 100), else: 0

    assigns
    |> assign(:total, total)
    |> assign(:done, done)
    |> assign(:pct, pct)
  end

  defp kv_rows(flow) do
    [
      {gettext("Backlog"), Map.get(flow, :backlog, 0), "var(--st-backlog)"},
      {gettext("Ready"), Map.get(flow, :ready, 0), "var(--st-ready)"},
      {gettext("Doing"), Map.get(flow, :doing, 0), "var(--st-doing)"},
      {gettext("Review"), Map.get(flow, :review, 0), "var(--st-review)"},
      {gettext("Done"), Map.get(flow, :done, 0), "var(--st-done)"}
    ]
  end

  # Duplicated verbatim from KanbanWeb.TargetsStrip so the hero badge and the
  # boards-strip badge share one vocabulary (label + --st-* token per status).
  defp status_badge(:complete), do: {"done", gettext("Complete")}
  defp status_badge(:on_track), do: {"ready", gettext("On-track")}
  defp status_badge(:at_risk), do: {"doing", gettext("At-risk")}
  defp status_badge(:missed), do: {"blocked", gettext("Missed")}

  defp badge_style(token) do
    [
      "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
      "background: var(--st-#{token}-soft); color: var(--st-#{token});",
      "font-family: var(--font-mono); font-weight: 600;"
    ]
  end

  defp format_target_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")
  defp format_target_date(_), do: nil

  defp present_or_nil(nil), do: nil
  defp present_or_nil(""), do: nil
  defp present_or_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp present_or_nil(_), do: nil
end
