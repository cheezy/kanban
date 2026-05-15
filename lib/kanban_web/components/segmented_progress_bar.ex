defmodule KanbanWeb.SegmentedProgressBar do
  @moduledoc """
  Segmented progress bar used by the active-goals strip above the kanban
  columns and by the per-goal view page header. Renders one colored
  segment per non-zero status bucket (`:done`, `:review`, `:doing`,
  `:ready`, `:backlog`) — segment widths are proportional to their
  count.

  Extracted from `KanbanWeb.GoalsStrip` so both surfaces consume the
  exact same visualization — adding a status, tweaking a token, or
  changing the segment order is a single-file change here.
  """
  use KanbanWeb, :html

  @segment_order [:done, :review, :doing, :ready, :backlog]

  @doc """
  Renders the segmented progress bar.

  ## Attrs

    * `flow` — map of status counts: `%{done: n, review: n, doing: n,
      ready: n, backlog: n, total: n}`. Required. Missing keys are
      treated as 0; a zero-segment status is omitted from the bar.
    * `size` — `:sm` (compact, 96px wide, 10px tall — strip default)
      or `:lg` (full-width, 14px tall — goal-view default).
      Default `:sm`.
    * `aria_label` — accessibility label for the bar. Default
      `"Goal progress by status"`.
  """
  attr :flow, :map, required: true
  attr :size, :atom, default: :sm, values: [:sm, :lg]
  attr :aria_label, :string, default: nil

  def segmented_progress(assigns) do
    segments = build_segments(assigns.flow)

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:bar_height, bar_height(assigns.size))
      |> assign(:bar_width, bar_width(assigns.size))
      |> assign(:resolved_aria_label, assigns.aria_label || default_aria_label())

    ~H"""
    <div
      data-segmented-progress
      role="progressbar"
      aria-label={@resolved_aria_label}
      style={[
        "display: flex; height: #{@bar_height};",
        if(@bar_width, do: "width: #{@bar_width};", else: "width: 100%;"),
        "border-radius: 2px; overflow: hidden;",
        "background: var(--surface-sunken);"
      ]}
    >
      <span
        :for={{status, count} <- @segments}
        title={"#{status}: #{count}"}
        style={[
          "flex: #{count};",
          "background: #{status_color(status)};",
          "opacity: #{segment_opacity(status)};"
        ]}
      >
      </span>
    </div>
    """
  end

  # --- Helpers -----------------------------------------------------------

  defp build_segments(flow) do
    Enum.flat_map(@segment_order, fn status ->
      count = Map.get(flow, status, 0)
      if is_integer(count) and count > 0, do: [{status, count}], else: []
    end)
  end

  defp bar_height(:lg), do: "14px"
  defp bar_height(_), do: "10px"

  defp bar_width(:sm), do: "96px"
  defp bar_width(_), do: nil

  defp segment_opacity(:done), do: "1"
  defp segment_opacity(_), do: "0.85"

  defp default_aria_label do
    gettext("Goal progress by status")
  end

  defp status_color(:done), do: "var(--st-done)"
  defp status_color(:review), do: "var(--st-review)"
  defp status_color(:doing), do: "var(--st-doing)"
  defp status_color(:ready), do: "var(--st-ready)"
  defp status_color(:backlog), do: "var(--st-backlog)"
  defp status_color(_), do: "var(--ink-4)"
end
