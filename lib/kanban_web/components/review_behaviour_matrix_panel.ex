defmodule KanbanWeb.ReviewBehaviourMatrixPanel do
  @moduledoc """
  "BEHAVIOUR/TEST MATRIX" panel for the Review queue detail view at `/review`.

  Renders the behaviour/test matrix the Stride task-reviewer agent echoes back
  inside `reviewer_result["behaviour_test_matrix"]["rows"]`, normalized by
  `KanbanWeb.ReviewBehaviourMatrix.rows/1`. Each row becomes one stacked card:
  the category chip and the behaviour to verify on the first line, the planned
  test name, the test type and a colour-coded status pill on the second.

  That is the `Category | Behaviour | test name | Type | Status` order of the
  task form's own matrix editor, stacked rather than columnar because the review
  detail pane is narrow — the editor's five-column header is itself
  `hidden sm:flex` on a full-width form, so reproducing it here would wrap badly.
  Both lines wrap, and the category chip and status pill never shrink.

  Status tones use the same theme tokens as the verdict pills, so they stay
  legible in both light and dark mode: `passing` green, `failing` red, `planned`
  neutral, `not_applicable` muted. Every pill is outlined — a soft status fill
  alone is only ~1.05:1 against the card in either theme — so all four read as
  capsules rather than the tinted ones reading as bare text. An unrecognized
  status renders as a neutral pill labelled with the raw value rather than
  disappearing.

  Completions with no matrix verdict — every completion before W1920 — render
  nothing at all, so the caller gates the wrapping section on
  `KanbanWeb.ReviewBehaviourMatrix.rows/1` returning a non-empty list and the
  panel never shows an empty shell.

  Row text is agent-supplied and is rendered through HEEx auto-escaping only —
  never `raw/1`.
  """
  use KanbanWeb, :html

  alias KanbanWeb.BehaviourTestLabels
  alias KanbanWeb.ReviewBehaviourMatrix
  alias KanbanWeb.ReviewReportHelpers.Tokens

  @doc """
  Renders the behaviour/test matrix rows for a task.

  Reads `reviewer_result` (atom- or string-keyed) and renders nothing when the
  verdict is absent or carries no well-formed rows.
  """
  attr :task, :map, required: true

  def review_behaviour_matrix(assigns) do
    assigns = assign(assigns, :rows, ReviewBehaviourMatrix.rows(assigns.task))

    ~H"""
    <ul
      :if={@rows != []}
      data-review-behaviour-matrix
      class="list-none p-0 m-0 flex flex-col gap-1.5"
    >
      <li :for={row <- @rows}>
        <.matrix_row row={row} />
      </li>
    </ul>
    """
  end

  attr :row, :map, required: true

  defp matrix_row(assigns) do
    status = assigns.row.status

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:pill_style, row_status_style(status))
      |> assign(:status_label, row_status_label(status))
      |> assign(:category_label, BehaviourTestLabels.category_label(assigns.row.category))
      |> assign(:behaviour, assigns.row.behaviour)
      |> assign(:test_name, assigns.row.test_name)
      |> assign(:type, assigns.row.type)

    ~H"""
    <div
      data-review-behaviour-row
      data-review-behaviour-status={@status || "unknown"}
      style={[
        "display: flex; flex-direction: column; gap: 4px;",
        "padding: 8px 10px; border-radius: 5px; min-width: 0;",
        "background: var(--surface-2); border: 1px solid var(--line);"
      ]}
    >
      <div style="display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; min-width: 0;">
        <span
          data-review-behaviour-category
          style={
            [
              "flex-shrink: 0; font-size: 10px; font-weight: 600;",
              "text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3);",
              # `flex-shrink: 0` keeps a real category from being squashed, but the
              # reviewer echo is only checked for a non-blank string — it does not
              # constrain the value to the seven canonical categories the way the
              # persisted schema does. These two bound the pathological case so an
              # over-long category wraps instead of overflowing the card.
              "max-width: 100%; overflow-wrap: anywhere;"
            ]
          }
        >
          {@category_label}
        </span>
        <span
          data-review-behaviour-text
          style={[
            "font-size: 12.5px; color: var(--ink); line-height: 1.45;",
            "overflow-wrap: anywhere; min-width: 0;"
          ]}
        >
          {@behaviour}
        </span>
      </div>
      <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 6px; min-width: 0;">
        <span
          :if={@test_name}
          data-review-behaviour-test-name
          style={[
            "font-size: 11.5px; color: var(--ink-2);",
            "overflow-wrap: anywhere; min-width: 0;"
          ]}
        >
          {@test_name}
        </span>
        <span
          :if={@type}
          data-review-behaviour-type
          style={[
            "font-size: 11px; color: var(--ink-3);",
            "overflow-wrap: anywhere; min-width: 0;"
          ]}
        >
          {@type}
        </span>
        <span
          data-review-behaviour-pill
          style={
            [
              "flex-shrink: 0; display: inline-flex; align-items: center;",
              "padding: 1px 7px; border-radius: 999px;",
              "font-size: 10.5px; font-weight: 600; letter-spacing: 0.02em;",
              "text-transform: uppercase; line-height: 1.5;",
              # Every pill is outlined, tinted ones included. A soft status fill is
              # only ~1.05:1 against the card it sits on in either theme — below
              # the 1.5:1 perceptibility floor this project sets for its own
              # hairlines — so without the border the `passing` / `failing` pills
              # read as bare coloured text while the neutral ones read as capsules,
              # inverting the visual hierarchy. A per-status clause may override.
              "border: 1px solid var(--line);",
              @pill_style
            ]
          }
        >
          {@status_label}
        </span>
      </div>
    </div>
    """
  end

  # `passing` / `failing` reuse the shared verdict tone pair so the green and red
  # token pairs stay defined in exactly one place. `verdict_tone_style/1` is a
  # boolean tri-state (true / false / other) and cannot express a four-way row
  # status, so `planned` (neutral, outlined) and `not_applicable` (muted) are
  # spelled out here against the same theme tokens. An unrecognized status falls
  # through to the neutral pill.
  defp row_status_style("passing"), do: Tokens.verdict_tone_style(true)
  defp row_status_style("failing"), do: Tokens.verdict_tone_style(false)
  defp row_status_style("planned"), do: neutral_pill_style("var(--ink-2)")
  defp row_status_style("not_applicable"), do: neutral_pill_style("var(--ink-3)")
  defp row_status_style(_), do: neutral_pill_style("var(--ink-2)")

  # The neutral fill needs the outline most: in the light theme
  # `--surface-sunken` is within ~1% lightness of the card's `--surface-2`, so
  # the pill shape would otherwise disappear entirely. The border is restated
  # here rather than left to the base style so that dependence is explicit at
  # the point it matters. `ink` is a literal token reference chosen here, never
  # row data.
  defp neutral_pill_style(ink) do
    "background: var(--surface-sunken); color: #{ink}; border: 1px solid var(--line);"
  end

  # BehaviourTestLabels translates every canonical status and passes an unknown
  # string through unchanged, so only a row with no status at all needs a label.
  defp row_status_label(status) when is_binary(status),
    do: BehaviourTestLabels.status_label(status)

  defp row_status_label(_), do: gettext("Unknown")
end
