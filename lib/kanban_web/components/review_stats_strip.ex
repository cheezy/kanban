defmodule KanbanWeb.ReviewStatsStrip do
  @moduledoc """
  Four-cell stats strip at the top of the Review Queue detail panel.

  Renders Acceptance / Tests / Diff / Hooks cells with tokenized tones —
  green (`var(--st-done)` via `TaskTokens.status_ink(:completed)`) when
  the corresponding `*_passed` boolean is `true`, red
  (`var(--st-blocked)` via `TaskTokens.status_ink(:blocked)`) when
  `false`, and neutral (`var(--ink)`) when the boolean is `nil`.

  Purely presentational — the LiveView is responsible for deriving the
  values and pass/fail booleans from the underlying Task.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskTokens

  @doc """
  Renders the four-cell stats strip.

  ## Attrs

    * `acceptance` — display string for the Acceptance cell (e.g. `"5/5"`).
      Defaults to em-dash when nil.
    * `acceptance_passed` — boolean (or nil for neutral) toggling the tone.
    * `tests` — display string for the Tests cell.
    * `tests_passed` — boolean (or nil).
    * `diff` — display string for the Diff cell (e.g. `"3 files"`).
    * `hooks` — display string for the Hooks cell.
    * `hooks_passed` — boolean (or nil).
  """
  attr :acceptance, :string, default: nil
  attr :acceptance_passed, :any, default: nil
  attr :tests, :string, default: nil
  attr :tests_passed, :any, default: nil
  attr :diff, :string, default: nil
  attr :diff_passed, :any, default: nil
  attr :hooks, :string, default: nil
  attr :hooks_passed, :any, default: nil

  def review_stats_strip(assigns) do
    ~H"""
    <dl
      data-review-stats-strip
      style={[
        "display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));",
        "margin: 0; padding: 0;",
        "background: var(--surface);",
        "border-top: 1px solid var(--line);",
        "border-bottom: 1px solid var(--line);"
      ]}
    >
      <.cell
        marker="acceptance"
        label={gettext("Acceptance")}
        value={@acceptance}
        tone={tone_for(@acceptance_passed)}
        border_right={true}
      />
      <.cell
        marker="tests"
        label={gettext("Testing strategy")}
        value={@tests}
        tone={tone_for(@tests_passed)}
        border_right={true}
      />
      <.cell
        marker="diff"
        label={gettext("Patterns")}
        value={@diff}
        tone={tone_for(@diff_passed)}
        border_right={true}
      />
      <.cell
        marker="hooks"
        label={gettext("Pitfalls")}
        value={@hooks}
        tone={tone_for(@hooks_passed)}
        border_right={false}
      />
    </dl>
    """
  end

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :tone, :string, required: true
  attr :border_right, :boolean, required: true

  defp cell(assigns) do
    ~H"""
    <div
      data-review-stats-cell={@marker}
      style={[
        "padding: 12px 18px;",
        if(@border_right, do: "border-right: 1px solid var(--line);", else: "")
      ]}
    >
      <dt style={[
        "margin: 0;",
        "font-size: 10px; font-weight: 600;",
        "text-transform: uppercase; letter-spacing: 0.08em;",
        "color: var(--ink-3);"
      ]}>
        {@label}
      </dt>
      <dd style={[
        "margin: 4px 0 0;",
        "font-size: 18px; font-weight: 600;",
        "color: #{@tone};",
        "font-variant-numeric: tabular-nums;"
      ]}>
        {display_value(@value)}
      </dd>
    </div>
    """
  end

  defp tone_for(true), do: TaskTokens.status_ink(:completed)
  defp tone_for(false), do: TaskTokens.status_ink(:blocked)
  defp tone_for(_), do: "var(--ink)"

  defp display_value(nil), do: "—"
  defp display_value(""), do: "—"
  defp display_value(value), do: value
end
