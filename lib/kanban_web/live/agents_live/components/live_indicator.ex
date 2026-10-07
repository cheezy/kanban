defmodule KanbanWeb.AgentsLive.Components.LiveIndicator do
  @moduledoc """
  The "live · N connected" strip at the top of `KanbanWeb.AgentsLive`'s second
  tier: a pulsing dot, the "live" label and the Presence-backed viewer count.

  Split out of `KanbanWeb.AgentsLive` to keep it under the module-size
  guideline in `AGENTS.md`. Purely presentational: the LiveView keeps the
  Presence subscription and the `connected_count` assign (refreshed on each
  `presence_diff`) and passes the count in. Moved unchanged; no DB access.
  """
  use KanbanWeb, :html

  attr :connected_count, :integer, required: true

  def live_indicator(assigns) do
    ~H"""
    <div
      data-agents-live-indicator
      style={[
        "display: flex; align-items: center; gap: 6px;",
        "padding: 6px 24px;",
        "font-size: 11px;",
        "color: var(--ink-3);",
        "border-bottom: 1px solid var(--line);"
      ]}
    >
      <span
        aria-hidden="true"
        style={[
          "width: 7px; height: 7px; border-radius: 50%;",
          "background: var(--st-done);",
          "animation: sp-pulse 1.2s ease-in-out infinite;"
        ]}
      />
      <span style="font-weight: 500; color: var(--ink-2);">{gettext("live")}</span>
      <span>·</span>
      <span>{live_indicator_label(@connected_count)}</span>
    </div>
    """
  end

  defp live_indicator_label(count) do
    ngettext("%{count} connected", "%{count} connected", count, count: count)
  end
end
