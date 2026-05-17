defmodule KanbanWeb.AgentActivityFeed do
  @moduledoc """
  Right-rail scrolling event feed for the Agents view.

  Renders two stacked pieces:

    * A row of filter tabs (`All / Claims / Hooks / Completions`). Tab
      clicks dispatch a `phx-click` event whose name is provided by the
      caller via `:on_filter_change`, with a `phx-value-filter` carrying
      the clicked tab's atom (as a string).
    * A vertical list of activity rows, one per `%Kanban.Agents.Event{}`
      in `:events`. Each row uses a five-column grid:
      `54px time / 18px kind icon / 26px avatar / 1fr text / auto chips`.

  The component is **purely presentational** — it does not filter the
  events itself. The caller passes in only the events it wants rendered;
  this component simply emits a `phx-click` when a tab is pressed and lets
  the LiveView decide which events to send back.

  Kind icons and tones come from `KanbanWeb.TaskTokens.kind_icon/1` and
  `KanbanWeb.TaskTokens.kind_tone/1` so the palette is shared with task
  status pills (claim ↔ doing, complete ↔ review, review ↔ done).

  The `:hooks` filter tab is wired here for parity with the mobile design,
  but `Kanban.Agents.Event` does not currently emit a `:hook` kind. The
  upstream filter therefore decides which events to send — this component
  renders whatever it is given.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.TaskTokens

  @filters [:all, :claims, :hooks, :completions]

  @doc """
  Renders the filter tabs and event-row feed.

  ## Attrs

    * `events` — list of `%Kanban.Agents.Event{}` (or compatible map).
      Required.
    * `filter` — currently active filter atom; one of
      `:all | :claims | :hooks | :completions`. Required.
    * `on_filter_change` — `phx-click` event name fired when a tab is
      clicked. The clicked tab's atom is sent as `phx-value-filter`.
      Required.
  """
  attr :events, :list, required: true
  attr :filter, :atom, required: true, values: @filters
  attr :on_filter_change, :string, required: true

  def feed(assigns) do
    ~H"""
    <section
      data-agent-feed
      class="stride-screen"
      style={[
        "display: flex; flex-direction: column; gap: 10px;",
        "min-height: 0;"
      ]}
    >
      <.tab_row filter={@filter} on_filter_change={@on_filter_change} />

      <p
        :if={@events == []}
        data-agent-feed-empty
        style={[
          "margin: 0; padding: 16px;",
          "font-size: 12px; font-style: italic;",
          "color: var(--ink-3);",
          "text-align: center;"
        ]}
      >
        {gettext("No recent activity.")}
      </p>

      <ul
        :if={@events != []}
        style={[
          "margin: 0; padding: 0; list-style: none;",
          "display: flex; flex-direction: column; gap: 4px;",
          "overflow-y: auto; min-height: 0;"
        ]}
      >
        <.row :for={event <- @events} event={event} />
      </ul>
    </section>
    """
  end

  attr :filter, :atom, required: true
  attr :on_filter_change, :string, required: true

  defp tab_row(assigns) do
    ~H"""
    <div
      data-agent-feed-tabs
      role="tablist"
      style="display: flex; gap: 4px; flex-wrap: wrap;"
    >
      <.tab
        :for={tab <- tabs()}
        value={tab}
        active={tab == @filter}
        on_click={@on_filter_change}
      />
    </div>
    """
  end

  defp tabs, do: @filters

  attr :value, :atom, required: true
  attr :active, :boolean, required: true
  attr :on_click, :string, required: true

  defp tab(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      data-agent-feed-tab={@value}
      aria-selected={if @active, do: "true", else: "false"}
      phx-click={@on_click}
      phx-value-filter={Atom.to_string(@value)}
      class="min-h-11 min-w-11 md:min-h-0 md:min-w-0 inline-flex items-center justify-center focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      style={[
        "padding: 4px 10px; border-radius: 12px;",
        "font-size: 11.5px; font-weight: 500;",
        "cursor: pointer; line-height: 1.4;",
        tab_palette(@active)
      ]}
    >
      {filter_label(@value)}
    </button>
    """
  end

  defp tab_palette(true) do
    "background: var(--ink); color: var(--surface); border: 1px solid var(--ink);"
  end

  defp tab_palette(false) do
    "background: var(--surface-sunken); color: var(--ink-3); border: 1px solid var(--line);"
  end

  attr :event, :map, required: true

  defp row(assigns) do
    ~H"""
    <li
      data-agent-feed-row
      data-agent-feed-kind={@event.kind}
      class="grid grid-cols-[44px_14px_20px_1fr_auto] sm:grid-cols-[54px_18px_26px_1fr_auto] items-center gap-1.5 sm:gap-2"
      style={[
        "padding: 6px 4px;",
        "font-size: 12px;",
        "border-bottom: 1px solid var(--line);"
      ]}
    >
      <time
        datetime={DateTime.to_iso8601(@event.at)}
        style={[
          "color: var(--ink-3);",
          "font-size: 11px;",
          "font-variant-numeric: tabular-nums;"
        ]}
      >
        {format_time(@event.at)}
      </time>

      <span
        aria-hidden="true"
        style={[
          "display: inline-flex; align-items: center; justify-content: center;",
          "color: #{TaskTokens.kind_tone(@event.kind)};"
        ]}
      >
        <.icon name={TaskTokens.kind_icon(@event.kind)} class="w-4 h-4" />
      </span>

      <.row_avatar actor={@event.actor} />

      <div style={[
        "min-width: 0;",
        "color: var(--ink);",
        "white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"
      ]}>
        <span :if={@event.actor} style="font-weight: 600;">{@event.actor}</span>
        <span style="color: var(--ink-3);">{TaskTokens.kind_label(@event.kind)}</span>
        <span :if={@event.identifier} style="font-weight: 600; letter-spacing: 0.02em;">
          {@event.identifier}
        </span>
        <span :if={@event.title} style="color: var(--ink-2);">— {@event.title}</span>
      </div>

      <.chips event={@event} />
    </li>
    """
  end

  attr :actor, :any, required: true

  defp row_avatar(%{actor: nil} = assigns) do
    ~H"""
    <span
      data-agent-feed-avatar-fallback
      aria-hidden="true"
      style={[
        "width: 26px; height: 26px; border-radius: 4px;",
        "background: var(--surface-sunken); border: 1px solid var(--line);"
      ]}
    />
    """
  end

  defp row_avatar(assigns) do
    ~H"""
    <Avatar.avatar
      kind={:agent}
      name={@actor}
      palette={AvatarPalette.for_agent(@actor)}
      size={26}
    />
    """
  end

  attr :event, :map, required: true

  defp chips(assigns) do
    has_move = not is_nil(assigns.event.move_to)
    has_cycle = not is_nil(assigns.event.cycle_time_minutes)
    assigns = assign(assigns, has_any: has_move or has_cycle)

    ~H"""
    <div
      :if={@has_any}
      style="display: inline-flex; align-items: center; gap: 4px;"
    >
      <span
        :if={@event.move_to}
        data-agent-feed-move-chip
        style={[
          "padding: 2px 7px; border-radius: 999px;",
          "font-size: 10.5px; font-weight: 500;",
          "background: #{TaskTokens.status_soft(@event.move_to)};",
          "color: #{TaskTokens.status_ink(@event.move_to)};"
        ]}
      >
        {TaskTokens.status_label(@event.move_to)}
      </span>
      <span
        :if={@event.cycle_time_minutes}
        data-agent-feed-cycle-chip
        style={[
          "padding: 2px 7px; border-radius: 999px;",
          "font-size: 10.5px; font-weight: 500;",
          "background: var(--surface-sunken);",
          "color: var(--ink-3);",
          "font-variant-numeric: tabular-nums;"
        ]}
      >
        {format_cycle_time(@event.cycle_time_minutes)}
      </span>
    </div>
    """
  end

  defp filter_label(:all), do: gettext("All")
  defp filter_label(:claims), do: gettext("Claims")
  defp filter_label(:hooks), do: gettext("Hooks")
  defp filter_label(:completions), do: gettext("Completions")

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp format_cycle_time(minutes) when is_integer(minutes) and minutes >= 60 do
    hours = div(minutes, 60)
    rem_min = rem(minutes, 60)
    gettext("%{h}h %{m}m", h: hours, m: rem_min)
  end

  defp format_cycle_time(minutes) when is_integer(minutes) do
    gettext("%{m}m", m: minutes)
  end
end
