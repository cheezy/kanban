defmodule KanbanWeb.TimeAgo do
  @moduledoc """
  Shared relative-age formatting for timestamps rendered as "just now",
  "30s ago", "5m ago", "3h ago", or "2d ago".

  Extracted from the identical private copies that previously lived in
  `KanbanWeb.ArchiveRow`, `KanbanWeb.ReviewDetailHeader`, and
  `KanbanWeb.ReviewQueueItem` (W1080). Two granularities exist because the
  call sites had intentionally diverged:

    * `:fine` — sub-minute ages render with second precision ("just now"
      under 5 seconds, then "30s ago"). Used by the review queue surfaces.
    * `:coarse` — anything under a minute renders as "just now". Used by
      the archive rows.

  All gettext message ids are unchanged from the original copies so
  existing translations keep applying.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  Formats the age of a `DateTime` relative to now. Returns `""` for `nil`.

  ## Examples

      TimeAgo.format_age(completed_at, :fine)
      TimeAgo.format_age(archived_at, :coarse)
  """
  def format_age(nil, _granularity), do: ""

  def format_age(%DateTime{} = dt, granularity) when granularity in [:fine, :coarse] do
    DateTime.utc_now()
    |> DateTime.diff(dt, :second)
    |> age_label(granularity)
  end

  defp age_label(seconds, :fine) when seconds < 5, do: gettext("just now")
  defp age_label(seconds, :fine) when seconds < 60, do: gettext("%{s}s ago", s: seconds)

  defp age_label(seconds, :coarse) when seconds < 60, do: gettext("just now")

  defp age_label(seconds, _granularity) when seconds < 3600,
    do: gettext("%{m}m ago", m: div(seconds, 60))

  defp age_label(seconds, _granularity) when seconds < 86_400,
    do: gettext("%{h}h ago", h: div(seconds, 3600))

  defp age_label(seconds, _granularity), do: gettext("%{d}d ago", d: div(seconds, 86_400))
end
