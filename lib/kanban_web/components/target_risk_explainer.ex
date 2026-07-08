defmodule KanbanWeb.TargetRiskExplainer do
  @moduledoc """
  Top-of-page explainer on the Agents view that turns "a target is at risk"
  into a concrete reason: for each **at-risk** delivery target it lists the
  target's stalled member goals and, under each goal, the stuck or dormant
  agents that are stalling it — tying a named agent stall to the named target
  it endangers.

  It binds the `:targets` list from `Kanban.Targets.DeliveryRollup.build/2`,
  consuming the per-goal `stalled_details` breakdown the rollup derives; it runs
  no queries of its own, so every target, goal, and agent already reflects only
  what the caller can access. A target with no stalled work — and the component
  as a whole when nothing is at risk — renders nothing.

  Like the sibling Agents components it uses ONLY Stride custom-property tokens
  (`var(--surface)`, `var(--ink)`, `var(--ink-2)`, `var(--ink-3)`,
  `var(--line)`, `var(--st-*)`) — no daisyUI classes and no hardcoded colors —
  so it stays legible in both light and dark mode, and every string flows
  through `gettext/1`. Agent identity (avatar + name) mirrors
  `KanbanWeb.AgentRosterCard`.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette

  @doc """
  Renders the at-risk target explainer.

  ## Attrs

    * `targets` — the `:targets` list from `Kanban.Targets.DeliveryRollup.build/2`.
      Required. Only entries whose `:status` is `:at_risk` and that have a
      non-empty `:stalled_details` are shown; when none qualify the component
      renders nothing.
  """
  attr :targets, :list, required: true

  attr :reassignable_goal_ids, :any,
    default: nil,
    doc: "MapSet of goal ids the viewer may reassign; a Reassign control renders for each."

  attr :on_reassign, :string,
    default: nil,
    doc: "handle_event name pushed (with phx-value-goal-id) when a Reassign control is clicked."

  def target_risk_explainer(assigns) do
    assigns = assign(assigns, :at_risk, Enum.filter(assigns.targets, &at_risk_with_stall?/1))

    ~H"""
    <section
      :if={@at_risk != []}
      data-target-risk-explainer
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
        {gettext("Why targets are at risk")}
      </h2>

      <.target_card
        :for={entry <- @at_risk}
        entry={entry}
        reassignable_goal_ids={@reassignable_goal_ids}
        on_reassign={@on_reassign}
      />
    </section>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :entry, :map, required: true
  attr :reassignable_goal_ids, :any, required: true
  attr :on_reassign, :string, default: nil

  # One at-risk target: its name, an At-risk badge, and a block per stalled goal.
  defp target_card(assigns) do
    ~H"""
    <div
      data-target-risk-card={@entry.target.id}
      style={[
        "display: flex; flex-direction: column; gap: 8px;",
        "padding: 10px 12px;",
        "border: 1px solid var(--st-doing);",
        "border-left: 3px solid var(--st-doing);",
        "border-radius: 6px;",
        "background: var(--surface);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px;">
        <span style="font-size: 13px; font-weight: 600; color: var(--ink);">
          {@entry.target.name}
        </span>
        <span style={[
          "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
          "background: var(--st-doing-soft); color: var(--st-doing);",
          "font-family: var(--font-mono); font-weight: 600;"
        ]}>
          {gettext("At-risk")}
        </span>
      </div>

      <.goal_block
        :for={detail <- @entry.stalled_details}
        detail={detail}
        reassignable_goal_ids={@reassignable_goal_ids}
        on_reassign={@on_reassign}
      />
    </div>
    """
  end

  attr :detail, :map, required: true
  attr :reassignable_goal_ids, :any, required: true
  attr :on_reassign, :string, default: nil

  # One stalled goal and the stuck/dormant agents stalling it, plus a Reassign
  # control when the viewer is authorized (server-cleared via can_intervene?/2).
  defp goal_block(assigns) do
    ~H"""
    <div
      data-target-risk-goal={@detail.goal.id}
      style={[
        "display: flex; flex-direction: column; gap: 5px;",
        "padding-left: 10px; border-left: 2px solid var(--line);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
        <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
          {@detail.goal.title}
        </span>
        <button
          :if={@on_reassign && reassignable?(@reassignable_goal_ids, @detail.goal.id)}
          type="button"
          phx-click={@on_reassign}
          phx-value-goal-id={@detail.goal.id}
          data-reassign-trigger={@detail.goal.id}
          style={[
            "font-size: 9.5px; font-weight: 600;",
            "padding: 1px 7px; border-radius: 3px;",
            "border: 1px solid var(--line);",
            "background: var(--surface-2); color: var(--ink-2);",
            "font-family: var(--font-mono); cursor: pointer; flex-shrink: 0;"
          ]}
        >
          {gettext("Reassign")}
        </button>
      </div>

      <.agent_row :for={agent <- @detail.agents} agent={agent} />
    </div>
    """
  end

  # Uses the Stride custom-property token vocabulary (not daisyUI classes) to
  # match the surrounding explainer, so the control stays legible in both themes
  # without a hardcoded color; membership is nil-safe for standalone renders.
  defp reassignable?(nil, _goal_id), do: false
  defp reassignable?(ids, goal_id), do: MapSet.member?(ids, goal_id)

  attr :agent, :map, required: true

  # One stalled agent: avatar, name, and a chip per stall reason (stuck/dormant).
  defp agent_row(assigns) do
    ~H"""
    <div
      data-target-risk-agent={@agent.name}
      style="display: inline-flex; align-items: center; gap: 6px; min-width: 0;"
    >
      <Avatar.avatar
        kind={:agent}
        name={@agent.name}
        palette={AvatarPalette.for_agent(@agent.name)}
        size={20}
      />
      <span style={[
        "font-size: 11.5px; color: var(--ink);",
        "white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"
      ]}>
        {@agent.name}
      </span>
      <span :if={@agent.stuck} data-target-risk-reason="stuck" style={reason_chip("blocked")}>
        {gettext("Stuck")}
      </span>
      <span :if={@agent.dormant} data-target-risk-reason="dormant" style={reason_chip("review")}>
        {gettext("Dormant")}
      </span>
    </div>
    """
  end

  # A stall-reason chip toned by an --st-* token pair (soft background + ink).
  defp reason_chip(token) do
    [
      "font-size: 9px; padding: 1px 5px; border-radius: 3px;",
      "background: var(--st-#{token}-soft); color: var(--st-#{token});",
      "font-family: var(--font-mono); font-weight: 600; flex-shrink: 0;"
    ]
  end

  defp at_risk_with_stall?(%{status: :at_risk, stalled_details: [_ | _]}), do: true
  defp at_risk_with_stall?(_), do: false
end
