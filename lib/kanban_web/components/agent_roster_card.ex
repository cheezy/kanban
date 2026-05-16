defmodule KanbanWeb.AgentRosterCard do
  @moduledoc """
  Purely presentational card for the left-roster column on the Agents view.

  Renders one agent row: a 28px avatar, the agent's name, an animated
  status dot, an optional current-task pill (only while the agent is
  `:working`), capability pills, and a four-cell stats grid
  (Today / 7d / Success / Claims).

  All design tokens come from the `.stride-screen` cascade in
  `assets/css/app.css`. The status-dot pulse animation
  (`@keyframes sp-pulse`) is defined in that file. Every visible string is
  wrapped in `gettext/1` so the component participates in the project's
  translation pipeline.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette

  @doc """
  Renders one roster card.

  ## Attrs

    * `agent` — a `%Kanban.Agents.Agent{}` struct (or equivalent map)
      with `:name`, `:status`, `:current_task`, `:capabilities`,
      `:today`, `:last_7d`, `:success_rate`, and `:claim_count`.
  """
  attr :agent, :map, required: true

  def card(assigns) do
    ~H"""
    <article
      data-agent-roster-card
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 10px;",
        "padding: 14px;",
        "border: 1px solid var(--line);",
        "border-radius: 10px;",
        "background: var(--surface);"
      ]}
    >
      <header style="display: flex; align-items: center; gap: 10px;">
        <Avatar.avatar
          kind={:agent}
          name={@agent.name}
          palette={AvatarPalette.for_agent(@agent.name)}
          size={28}
        />
        <div style="flex: 1; min-width: 0;">
          <div style={[
            "font-size: 13px; font-weight: 600;",
            "color: var(--ink);",
            "white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"
          ]}>
            {@agent.name}
          </div>
        </div>
        <.status_dot status={@agent.status} />
      </header>

      <.current_task_pill
        :if={@agent.status == :working and @agent.current_task}
        task={@agent.current_task}
      />

      <.capability_pills :if={@agent.capabilities != []} capabilities={@agent.capabilities} />

      <.stats_grid agent={@agent} />
    </article>
    """
  end

  attr :status, :atom, required: true

  defp status_dot(assigns) do
    assigns = assign(assigns, :color, status_dot_color(assigns.status))

    ~H"""
    <span
      data-agent-status-dot
      data-agent-status={@status}
      title={status_label(@status)}
      aria-label={status_label(@status)}
      style={[
        "width: 8px; height: 8px; border-radius: 50%;",
        "background: #{@color};",
        "animation: sp-pulse 1.2s ease-in-out infinite;",
        "flex-shrink: 0;"
      ]}
    />
    """
  end

  attr :task, :map, required: true

  defp current_task_pill(assigns) do
    ~H"""
    <div
      data-agent-current-task
      style={[
        "display: inline-flex; align-items: center; gap: 6px;",
        "padding: 4px 8px;",
        "background: var(--st-doing-soft);",
        "color: var(--st-doing);",
        "border-radius: 999px;",
        "font-size: 11px; font-weight: 500;",
        "max-width: 100%;"
      ]}
    >
      <span style="font-weight: 600; letter-spacing: 0.02em;">{@task.identifier}</span>
      <span style="opacity: 0.85; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">
        {@task.title}
      </span>
    </div>
    """
  end

  attr :capabilities, :list, required: true

  defp capability_pills(assigns) do
    ~H"""
    <ul
      data-agent-capabilities
      style="display: flex; flex-wrap: wrap; gap: 4px; list-style: none; padding: 0; margin: 0;"
    >
      <li
        :for={cap <- @capabilities}
        style={[
          "padding: 2px 7px;",
          "background: var(--stride-violet-soft);",
          "color: var(--stride-violet);",
          "border-radius: 999px;",
          "font-size: 11px; font-weight: 500;"
        ]}
      >
        {cap}
      </li>
    </ul>
    """
  end

  attr :agent, :map, required: true

  defp stats_grid(assigns) do
    ~H"""
    <dl
      data-agent-stats-grid
      style={[
        "display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 6px;",
        "margin: 0; padding: 0;"
      ]}
    >
      <.stat label={gettext("Today")} value={@agent.today} />
      <.stat label={gettext("7d")} value={@agent.last_7d} />
      <.stat label={gettext("Success")} value={format_percent(@agent.success_rate)} />
      <.stat label={gettext("Claims")} value={@agent.claim_count} />
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 2px;">
      <dt style={[
        "font-size: 10px; text-transform: uppercase; letter-spacing: 0.04em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 13px; font-weight: 600;",
        "color: var(--ink);",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp status_dot_color(:working), do: "var(--st-doing)"
  defp status_dot_color(:waiting), do: "var(--ink-3)"
  defp status_dot_color(:idle), do: "var(--ink-4)"

  defp status_label(:working), do: gettext("Working")
  defp status_label(:waiting), do: gettext("Waiting for review")
  defp status_label(:idle), do: gettext("Idle")

  defp format_percent(rate) when is_float(rate) or is_integer(rate) do
    "#{round(rate * 100)}%"
  end

  defp format_percent(_), do: "0%"
end
