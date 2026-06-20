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
      with `:name`, `:owner_key`, `:owner`, `:status`, `:current_task`,
      `:capabilities`, `:today`, `:last_7d`, `:success_rate`, and
      `:claim_count`. The `:owner` (a `%{name, email}`-shaped map or `nil`)
      renders as a secondary line under the agent name when present.
    * `on_select` — optional LiveView event name fired when the card is
      activated. The click carries both `phx-value-agent` (the agent's
      name) and `phx-value-owner` (the non-sensitive `owner_key`), which
      together form the agent's identity (W1244) — same-named agents under
      different humans are independently selectable. When set, the card
      becomes a keyboard-operable button (role, `aria-pressed`, `tabindex`,
      focus-visible outline); when `nil` the card is purely presentational.
    * `selected?` — whether this card is the currently-selected agent;
      drives the highlighted border/background and `aria-pressed`.
  """
  attr :agent, :map, required: true
  attr :on_select, :string, default: nil
  attr :selected?, :boolean, default: false

  def card(assigns) do
    ~H"""
    <article
      data-agent-roster-card
      data-agent-name={@agent.name}
      data-agent-key={@agent.owner_key}
      data-agent-selected={to_string(@selected?)}
      role={@on_select && "button"}
      aria-pressed={@on_select && if(@selected?, do: "true", else: "false")}
      tabindex={@on_select && "0"}
      phx-click={@on_select}
      phx-value-agent={@agent.name}
      phx-value-owner={@agent.owner_key}
      class={
        "stride-screen" <>
          if(@on_select,
            do: " focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2",
            else: ""
          )
      }
      style={[
        "display: flex; flex-direction: column; gap: 10px;",
        "padding: 14px;",
        "border: 1px solid #{if @selected?, do: "var(--stride-violet)", else: "var(--line)"};",
        "border-radius: 10px;",
        "background: #{if @selected?, do: "var(--stride-violet-soft)", else: "var(--surface)"};",
        if(@on_select, do: "cursor: pointer;", else: "")
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
          <div
            :if={owner_label(@agent.owner)}
            data-agent-owner
            aria-label={gettext("Operator")}
            style={[
              "font-size: 11px; font-weight: 500;",
              "color: var(--ink-3);",
              "white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"
            ]}
          >
            {owner_label(@agent.owner)}
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
      class="grid grid-cols-2 gap-x-3 gap-y-2 m-0 p-0"
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
    <div style="display: flex; flex-direction: column; gap: 2px; min-width: 0;">
      <dt style={[
        "font-size: 10px; text-transform: uppercase; letter-spacing: 0.04em;",
        "color: var(--ink-3);",
        "overflow-wrap: anywhere;"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 0;",
        "font-size: 13px; font-weight: 600;",
        "color: var(--ink);",
        "font-variant-numeric: tabular-nums;",
        "overflow-wrap: anywhere;"
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

  # Derives the display label for the human owner behind an agent. Prefers
  # the owner's name, falls back to their email, and returns nil when no
  # owner is present so the card renders the agent name alone.
  defp owner_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp owner_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp owner_label(_), do: nil
end
