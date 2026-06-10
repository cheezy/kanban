defmodule KanbanWeb.Duration do
  @moduledoc """
  Shared minutes-to-duration formatting — "47m", "2h", "2h 41m" — with
  options covering the per-site variants the call sites had developed.

  Extracted from the four near-identical private formatters that previously
  lived in `KanbanWeb.ArchiveStatsStrip`, `KanbanWeb.ArchiveRow`,
  `KanbanWeb.GoalSidebar`, and `KanbanWeb.MetricsKpiStrip` (W1090). The
  intentional edge differences are explicit options, never silently
  unified:

    * `:nil_label` — rendered for `nil` and any non-integer input
      (default `"—"`)
    * `:zero_label` — rendered for `0` (default `"0m"`; the goal sidebar
      passes `"—"`)
    * `:pad_remainder` — zero-pads the minute remainder so 65 renders
      `"1h 05m"` (default `false`; the metrics KPI strip passes `true`)

  Outputs are plain interpolated strings, deliberately outside gettext,
  matching the originals.
  """

  @doc """
  Formats a number of minutes as a compact duration string.

  ## Examples

      Duration.format_minutes(47)                        #=> "47m"
      Duration.format_minutes(161)                       #=> "2h 41m"
      Duration.format_minutes(65, pad_remainder: true)   #=> "1h 05m"
      Duration.format_minutes(0, zero_label: "—")        #=> "—"
      Duration.format_minutes(nil)                       #=> "—"
  """
  def format_minutes(minutes, opts \\ [])

  def format_minutes(0, opts), do: Keyword.get(opts, :zero_label, "0m")

  def format_minutes(minutes, _opts) when is_integer(minutes) and minutes < 60 do
    "#{minutes}m"
  end

  def format_minutes(minutes, opts) when is_integer(minutes) do
    hours = div(minutes, 60)
    remainder = rem(minutes, 60)

    cond do
      remainder == 0 -> "#{hours}h"
      Keyword.get(opts, :pad_remainder, false) -> "#{hours}h #{padded(remainder)}m"
      true -> "#{hours}h #{remainder}m"
    end
  end

  def format_minutes(_other, opts), do: Keyword.get(opts, :nil_label, "—")

  defp padded(n) when is_integer(n) and n < 10, do: "0#{n}"
  defp padded(n) when is_integer(n), do: Integer.to_string(n)
end
