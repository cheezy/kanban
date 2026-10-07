defmodule KanbanWeb.AgentsLive.Components.Roster do
  @moduledoc """
  The agent-roster markup on `KanbanWeb.AgentsLive`: the left-hand roster
  aside (live agents, the empty-state line, and the collapsible Dormant group
  with each dormant agent's "last seen" label) and the "Filtering by <agent>"
  chip shown above the activity feed while a roster agent is selected.

  Split out of `KanbanWeb.AgentsLive` to keep it under the module-size
  guideline in `AGENTS.md`. Chosen as the seam because it was the largest
  stretch of the LiveView's template and is entirely presentational: it reads
  the roster/selection assigns the LiveView passes in and renders, pushing the
  `select_agent`, `toggle_dormant` and `clear_agent_filter` events to the
  LiveView, which keeps the `handle_event/3` clauses and the selection state.
  The helpers here (the roster card's target annotation, the dormant "last
  seen" label, the selected agent's display name) are used only by this
  markup. Moved unchanged; pure, no DB access.
  """
  use KanbanWeb, :html

  alias KanbanWeb.AgentRosterCard

  attr :agents, :list, required: true
  attr :dormant_agents, :list, required: true
  attr :dormant_expanded?, :boolean, required: true
  attr :selected_agent, :any, required: true
  attr :agent_targets, :map, required: true

  def roster(assigns) do
    ~H"""
    <aside
      data-agents-roster
      class="w-full md:w-[380px] md:flex-shrink-0 md:overflow-y-auto"
      style={[
        "padding: 16px;",
        "border-right: 1px solid var(--line);",
        "background: var(--surface-2);",
        "display: flex; flex-direction: column; gap: 8px;"
      ]}
    >
      <p
        :if={@agents == [] and @dormant_agents == []}
        data-agents-roster-empty
        style={[
          "margin: 0; padding: 16px; text-align: center;",
          "font-size: 12px; font-style: italic;",
          "color: var(--ink-3);"
        ]}
      >
        {gettext("No agents have activity yet.")}
      </p>
      <AgentRosterCard.card
        :for={agent <- @agents}
        agent={agent}
        annotation={primary_annotation(@agent_targets, agent)}
        on_select="select_agent"
        selected?={{agent.name, agent.owner_key} == @selected_agent}
      />

      <div
        :if={@dormant_agents != []}
        data-agents-dormant-group
        style={[
          "margin-top: 8px; padding-top: 8px;",
          "border-top: 1px solid var(--line);",
          "display: flex; flex-direction: column; gap: 8px;"
        ]}
      >
        <button
          type="button"
          phx-click="toggle_dormant"
          data-agents-dormant-toggle
          aria-expanded={to_string(@dormant_expanded?)}
          class="min-h-11 md:min-h-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style={[
            "display: flex; align-items: center; gap: 6px;",
            "width: 100%; padding: 4px 2px;",
            "background: transparent; border: 0; cursor: pointer;",
            "font-size: 11px; font-weight: 600;",
            "text-transform: uppercase; letter-spacing: 0.06em;",
            "color: var(--ink-3);"
          ]}
        >
          <.icon
            name={if @dormant_expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="w-3 h-3"
          />
          <span>{gettext("Dormant (%{count})", count: length(@dormant_agents))}</span>
        </button>

        <div
          :if={@dormant_expanded?}
          style="display: flex; flex-direction: column; gap: 8px;"
        >
          <div :for={agent <- @dormant_agents} data-agent-dormant-card>
            <AgentRosterCard.card
              agent={agent}
              annotation={primary_annotation(@agent_targets, agent)}
              on_select="select_agent"
              selected?={{agent.name, agent.owner_key} == @selected_agent}
            />
            <p style={[
              "margin: 2px 0 0; padding-left: 2px;",
              "font-size: 10px; color: var(--ink-3);"
            ]}>
              {format_last_seen(agent.last_active_at)}
            </p>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :selected_agent, :any, required: true

  def selected_agent_filter(assigns) do
    ~H"""
    <div
      :if={@selected_agent}
      data-agent-filter-indicator
      data-selected-agent={selected_agent_name(@selected_agent)}
      style={[
        "display: inline-flex; align-items: center; gap: 8px;",
        "align-self: flex-start;",
        "margin-bottom: 12px; padding: 4px 4px 4px 12px;",
        "background: var(--stride-violet-soft);",
        "color: var(--stride-violet);",
        "border-radius: 999px;",
        "font-size: 12px; font-weight: 500;"
      ]}
    >
      <span>{gettext("Filtering by %{agent}", agent: selected_agent_name(@selected_agent))}</span>
      <button
        type="button"
        phx-click="clear_agent_filter"
        data-clear-agent-filter
        class="min-h-11 md:min-h-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        style={[
          "display: inline-flex; align-items: center; gap: 4px;",
          "padding: 2px 9px;",
          "border: 1px solid var(--stride-violet); border-radius: 999px;",
          "background: transparent; color: var(--stride-violet);",
          "cursor: pointer; font-size: 11px; font-weight: 600; line-height: 1.4;"
        ]}
      >
        <span aria-hidden="true" style="display: inline-flex;">
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </span>
        <span>{gettext("Clear")}</span>
      </button>
    </div>
    """
  end

  # The single target+goal annotation a roster card renders for an agent, or nil
  # when the agent advances no target. When the agent works several targets the
  # most-endangered one wins (at-risk, then missed, then the first) so the card
  # surfaces the reason it was floated to the top.
  defp primary_annotation(agent_targets, agent) do
    agent_targets
    |> Map.get({agent.name, agent.owner_key}, [])
    |> pick_annotation()
  end

  defp pick_annotation([]), do: nil

  defp pick_annotation(entries) do
    Enum.find(entries, &(&1.status == :at_risk)) ||
      Enum.find(entries, &(&1.status == :missed)) ||
      hd(entries)
  end

  # The human-readable agent name from a selected identity, for display.
  defp selected_agent_name({name, _owner_key}), do: name

  # Compact "last seen Nd ago" label for a dormant agent's last activity.
  # Uses whole-days elapsed (the dormancy granularity) to avoid a relative-time
  # dependency; the count-only string sidesteps per-locale plural forms.
  defp format_last_seen(%NaiveDateTime{} = last_active_at) do
    days = NaiveDateTime.diff(NaiveDateTime.utc_now(), last_active_at, :day)
    gettext("Last seen %{days}d ago", days: days)
  end

  defp format_last_seen(_), do: "—"
end
