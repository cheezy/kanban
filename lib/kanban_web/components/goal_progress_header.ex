defmodule KanbanWeb.GoalProgressHeader do
  @moduledoc """
  Hero band rendered at the top of the per-goal view page. Mirrors the
  `<header>` block at lines 30-93 of
  `design_handoff_stride/design_source/screens/extras.jsx` (`GoalView`).

  Surfaces the goal's identifier, "Goal" pill, optional AI pill, priority
  dot + label, title (`<h1>`), optional `why` blurb, and a progress band
  that composes `KanbanWeb.SegmentedProgressBar` at `:lg`.

  Progress math (`done`, `total`, `by_status` counts) is computed by the
  LiveView and passed in — this component is pure presentation per the
  W550 pitfall.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.BoardHeader
  alias KanbanWeb.SegmentedProgressBar
  alias KanbanWeb.TaskTokens

  @doc """
  Renders the goal progress header.

  ## Attrs

    * `goal` — goal struct or map (`Map.get/3` access). Recognized fields:
      `:identifier`, `:title`, `:priority`, `:why`, `:ai_generated?` /
      `:ai_generated`.
    * `flow` — count map driving the segmented bar:
      `%{done, review, doing, ready, backlog, total}`. Required.
    * `by_status` — count map keyed by status atom for the per-status KV
      strip (`:backlog | :ready | :doing | :review | :done`). Defaults to
      the values inside `flow`.
  """
  attr :goal, :map, required: true
  attr :flow, :map, required: true
  attr :by_status, :map, default: nil
  attr :contributors, :list, default: []

  def goal_progress_header(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <header
      data-goal-progress-header
      class="stride-screen"
      style={[
        "padding: 20px 28px 18px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
        <span style="color: var(--stride-violet); display: inline-flex;">
          <.icon name="hero-flag" class="w-4 h-4" />
        </span>
        <span class="ident" style="font-size: 11.5px; color: var(--ink-2);">
          {@identifier}
        </span>
        <span style={[
          "display: inline-flex; align-items: center;",
          "padding: 2px 7px; border-radius: 999px;",
          "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
          "font-size: 10.5px; font-weight: 600;"
        ]}>
          {gettext("Goal")}
        </span>
        <BoardHeader.ai_pill :if={@ai_generated?} />
        <.priority_dot :if={@priority} priority={@priority} />
        <span :if={@priority} style="font-size: 11px; color: var(--ink-3);">
          {TaskTokens.priority_word(@priority)} {gettext("priority")}
        </span>
      </div>

      <h1 style={[
        "margin: 0; font-size: 26px; font-weight: 600;",
        "letter-spacing: -0.025em; text-wrap: pretty; color: var(--ink);"
      ]}>
        {@title}
      </h1>

      <p
        :if={@why}
        style={[
          "margin: 6px 0 0; font-size: 13px; color: var(--ink-2);",
          "max-width: 720px; text-wrap: pretty;"
        ]}
      >
        {@why}
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
            aria_label={gettext("Goal progress by child status")}
          />
        </div>

        <div style="display: flex; gap: 18px; flex-wrap: wrap;">
          <.kv :for={{label, count, tone} <- @kv_rows} label={label} count={count} tone={tone} />
        </div>

        <span style="flex: 1;"></span>

        <div :if={@contributors != []} data-goal-contributors>
          <div class="ucase" style="font-size: 9.5px; color: var(--ink-3); margin-bottom: 4px;">
            {gettext("Working on it")}
          </div>
          <Avatar.avatar_stack members={@contributors} max={5} size={22} />
        </div>
      </div>
    </header>
    """
  end

  # --- Sub-components ----------------------------------------------------

  attr :priority, :atom, required: true

  defp priority_dot(assigns) do
    assigns = assign(assigns, :color, TaskTokens.priority_color(assigns.priority))

    ~H"""
    <span
      aria-hidden="true"
      style={[
        "width: 6px; height: 6px; border-radius: 50%;",
        "background: #{@color}; flex-shrink: 0;"
      ]}
    >
    </span>
    """
  end

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
    by_status = assigns.by_status || flow_to_by_status(assigns.flow)

    assigns
    |> assign_goal_fields()
    |> assign_progress(by_status)
  end

  defp assign_goal_fields(assigns) do
    goal = assigns.goal

    assigns
    |> assign(:identifier, Map.get(goal, :identifier, ""))
    |> assign(:title, Map.get(goal, :title, ""))
    |> assign(:priority, Map.get(goal, :priority))
    |> assign(:why, present_or_nil(Map.get(goal, :why)))
    |> assign(:ai_generated?, ai_generated?(goal))
  end

  defp assign_progress(assigns, by_status) do
    total = Map.get(assigns.flow, :total) || sum_statuses(by_status)
    done = Map.get(assigns.flow, :done, 0)
    pct = if total > 0, do: round(done / total * 100), else: 0

    assigns
    |> assign(:by_status, by_status)
    |> assign(:total, total)
    |> assign(:done, done)
    |> assign(:pct, pct)
    |> assign(:kv_rows, kv_rows(by_status))
  end

  defp flow_to_by_status(flow) do
    %{
      backlog: Map.get(flow, :backlog, 0),
      ready: Map.get(flow, :ready, 0),
      doing: Map.get(flow, :doing, 0),
      review: Map.get(flow, :review, 0),
      done: Map.get(flow, :done, 0)
    }
  end

  defp sum_statuses(by_status) do
    Enum.reduce([:backlog, :ready, :doing, :review, :done], 0, fn k, acc ->
      acc + Map.get(by_status, k, 0)
    end)
  end

  defp kv_rows(by_status) do
    [
      {gettext("Backlog"), Map.get(by_status, :backlog, 0), "var(--st-backlog)"},
      {gettext("Ready"), Map.get(by_status, :ready, 0), "var(--st-ready)"},
      {gettext("Doing"), Map.get(by_status, :doing, 0), "var(--st-doing)"},
      {gettext("Review"), Map.get(by_status, :review, 0), "var(--st-review)"},
      {gettext("Done"), Map.get(by_status, :done, 0), "var(--st-done)"}
    ]
  end

  defp ai_generated?(goal) do
    Map.get(goal, :ai_generated?, false) || Map.get(goal, :ai_generated, false)
  end

  defp present_or_nil(nil), do: nil
  defp present_or_nil(""), do: nil
  defp present_or_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp present_or_nil(_), do: nil
end
