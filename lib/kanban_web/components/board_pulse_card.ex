defmodule KanbanWeb.BoardPulseCard do
  @moduledoc """
  Single-board card for the Boards index. Composes the identifier badge,
  name + AI Pill, description, 14-day pulse sparkline, throughput row,
  4-stat row (Open/Doing/Review/Done), member stack, and last-activity
  footer.

  Renders inside the `.stride-screen` CSS scope so the design tokens
  (`--surface`, `--line`, `--ink`, `--st-*`, `--stride-*`) resolve.

  Mirrors `BoardsIndex_Cards` in the design source
  `design_handoff_stride/design_source/screens/boards-index.jsx`
  (lines ~83-154). Reuses `KanbanWeb.Avatar.avatar_stack/1` (W525) and
  `KanbanWeb.PulseSparkline.pulse_sparkline/1` (W526).
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.PulseSparkline

  @doc """
  Renders a single pulse-card for one board.

  ## Attrs

    * `board` — a map (or `%Kanban.Boards.Board{}`) with `:id`, `:name`,
      `:description`, `:ai_optimized_board`, and `:metrics`. The metrics
      map must follow `Kanban.Boards.list_boards_with_metrics/2`:
      `:open`, `:doing`, `:review`, `:done`, `:throughput_14d`,
      `:pulse_14d`, `:active_agents_14d`, `:last_activity_at`.

  Two optional keys may also appear on the board map:

    * `:accent` — one of `:orange`, `:ready`, `:doing`, `:violet`,
      `:backlog`, `:blocked`. Drives the identifier badge color and the
      sparkline stroke. Defaults to `var(--ink-3)` when absent.
    * `:members` — pre-built list of `%{kind, name, palette}` maps to
      pass through to `Avatar.avatar_stack/1`. When absent, the card
      synthesizes a list from `metrics.active_agents_14d` using a
      rotating named-agent palette.
  """
  attr :board, :map, required: true

  def board_pulse_card(assigns) do
    assigns = assign(assigns, :accent_css, accent_color(Map.get(assigns.board, :accent)))

    ~H"""
    <.link
      navigate={~p"/boards/#{@board.id}"}
      class="block focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2"
      style="text-decoration: none; color: inherit; height: 100%;"
    >
      <div style={[
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 8px; padding: 14px 14px 12px;",
        "box-shadow: var(--shadow-sm);",
        "display: flex; flex-direction: column; gap: 12px;",
        "position: relative; overflow: hidden;",
        "height: 100%;"
      ]}>
        <.identifier_and_name board={@board} accent_css={@accent_css} />
        <.pulse_row board={@board} accent_css={@accent_css} />
        <.stat_row metrics={@board.metrics} />
        <.member_footer board={@board} />
      </div>
    </.link>
    """
  end

  attr :board, :map, required: true
  attr :accent_css, :string, required: true

  defp identifier_and_name(assigns) do
    ~H"""
    <div style="display: flex; align-items: flex-start; gap: 8px;">
      <span
        aria-hidden="true"
        style={[
          "width: 26px; height: 26px; border-radius: 6px;",
          "background: #{@accent_css};",
          "display: inline-flex; align-items: center; justify-content: center;",
          "color: var(--color-primary-content); font-size: 10px; font-weight: 700;",
          "font-family: var(--font-mono); letter-spacing: -0.02em; flex-shrink: 0;"
        ]}
      >
        {board_prefix(@board.name)}
      </span>
      <div style="flex: 1; min-width: 0;">
        <div style="display: flex; align-items: center; gap: 6px;">
          <h3 style="margin: 0; font-size: 13.5px; font-weight: 600; letter-spacing: -0.01em;">
            {@board.name}
          </h3>
          <span
            :if={Map.get(@board, :ai_optimized_board, false)}
            class="ucase"
            style={[
              "display: inline-flex; align-items: center; gap: 3px;",
              "padding: 2px 6px; border-radius: 999px;",
              "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
              "font-size: 9px; font-weight: 600; letter-spacing: 0.04em;"
            ]}
          >
            {gettext("AI")}
          </span>
        </div>
        <p
          :if={present?(Map.get(@board, :description))}
          style="margin: 2px 0 0; font-size: 11.5px; color: var(--ink-3); line-height: 1.45;"
        >
          {@board.description}
        </p>
      </div>
    </div>
    """
  end

  attr :board, :map, required: true
  attr :accent_css, :string, required: true

  defp pulse_row(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: space-between;">
      <div style="display: flex; flex-direction: column; gap: 1px;">
        <span class="ucase" style="font-size: 9.5px;">{gettext("Last 14 days")}</span>
        <span style="font-size: 11px; color: var(--ink-2);">
          <span style="color: var(--ink); font-weight: 600;">{@board.metrics.throughput_14d}</span>
          {gettext("throughput")}
        </span>
      </div>
      <PulseSparkline.pulse_sparkline
        data={@board.metrics.pulse_14d}
        color={@accent_css}
      />
    </div>
    """
  end

  attr :metrics, :map, required: true

  defp stat_row(assigns) do
    ~H"""
    <div style={[
      "display: grid; grid-template-columns: repeat(4, 1fr);",
      "border-top: 1px solid var(--line); padding-top: 10px; gap: 4px;"
    ]}>
      <.stat_cell label={gettext("To Do")} value={@metrics.open} tone="var(--ink)" />
      <.stat_cell label={gettext("Doing")} value={@metrics.doing} tone="var(--st-doing)" />
      <.stat_cell label={gettext("Review")} value={@metrics.review} tone="var(--st-review)" />
      <.stat_cell label={gettext("Done")} value={@metrics.done} tone="var(--st-done)" />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp stat_cell(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column;">
      <span class="ucase" style="font-size: 9.5px;">{@label}</span>
      <span style={[
        "font-size: 15px; font-weight: 600; color: #{@tone};",
        "font-feature-settings: 'tnum'; letter-spacing: -0.02em;"
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  attr :board, :map, required: true

  defp member_footer(assigns) do
    members = Map.get(assigns.board, :members) || synthetic_members(assigns.board.metrics)
    assigns = assign(assigns, :members, members)

    ~H"""
    <div style={[
      "display: flex; align-items: center; gap: 8px;",
      "padding-top: 10px; border-top: 1px solid var(--line);",
      "margin-top: auto;"
    ]}>
      <Avatar.avatar_stack members={@members} />
      <span style="flex: 1;"></span>
      <span
        class="ident"
        style="display: inline-flex; align-items: center; gap: 4px;"
        title={gettext("Last Activity")}
      >
        <.icon name="hero-clock" class="w-2.5 h-2.5" />
        {format_last_activity(@board.metrics.last_activity_at)}
      </span>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp accent_color(:orange), do: "var(--stride-orange)"
  defp accent_color(:ready), do: "var(--st-ready)"
  defp accent_color(:doing), do: "var(--st-doing)"
  defp accent_color(:violet), do: "var(--stride-violet)"
  defp accent_color(:backlog), do: "var(--st-backlog)"
  defp accent_color(:blocked), do: "var(--st-blocked)"
  defp accent_color(_other), do: "var(--ink-3)"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp board_prefix(name) when is_binary(name) do
    letters =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "")

    letters
    |> String.slice(0, 3)
    |> String.pad_trailing(3, "?")
  end

  defp board_prefix(_), do: "???"

  # Synthesize a small member list from the agent count so the card
  # works against the metrics map alone. The Boards LiveView is free to
  # override with a richer pre-built list via board.members.
  @agent_names ~w[Claude Cursor Aider Codex Gemini]
  @agent_palettes ~w[agent-claude agent-cursor agent-aider agent-codex agent-claude]

  defp synthetic_members(%{active_agents_14d: count}) when is_integer(count) and count > 0 do
    @agent_names
    |> Enum.zip(@agent_palettes)
    |> Enum.take(min(count, 5))
    |> Enum.map(fn {name, palette} -> %{kind: :agent, name: name, palette: palette} end)
  end

  defp synthetic_members(_metrics), do: []

  defp format_last_activity(nil), do: "—"

  defp format_last_activity(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n}m ago", n: div(diff, 60))
      diff < 86_400 -> gettext("%{n}h ago", n: div(diff, 3600))
      true -> gettext("%{n}d ago", n: div(diff, 86_400))
    end
  end
end
