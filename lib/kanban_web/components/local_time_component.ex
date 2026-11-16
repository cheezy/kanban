defmodule KanbanWeb.LocalTimeComponent do
  @moduledoc """
  The `<.local_time>` function component: an absolute date or time rendered in
  the viewer's timezone and language.

  It renders a `<time>` element whose `datetime` attribute is the ISO 8601 UTC
  form of the value, whatever the locale, and whose `title` is the full local
  date and time with the zone abbreviation. The text is
  `KanbanWeb.LocalTime.format/2` in the requested style.

  Imported into every HTML module through `KanbanWeb.html_helpers/0`, so it
  `use`s `Phoenix.Component` directly rather than `KanbanWeb, :html`, which
  would import this module into itself.
  """
  use Phoenix.Component

  alias KanbanWeb.LocalTime

  @doc """
  Renders `value` in the viewer's timezone and locale. Renders nothing for `nil`.

  ## Examples

      <.local_time value={@task.completed_at} />
      <.local_time value={@task.inserted_at} style={:short_date} class="text-xs" />
  """
  attr :value, :any,
    required: true,
    doc: "a DateTime, NaiveDateTime (treated as UTC), Date or nil"

  attr :style, :atom,
    default: :datetime,
    values: [
      :datetime,
      :date,
      :short_date,
      :short_datetime,
      :month_day,
      :time,
      :month_year,
      :weekday_date
    ]

  attr :rest, :global

  def local_time(assigns) do
    ~H"""
    <time
      :if={@value}
      datetime={LocalTime.utc_iso8601(@value)}
      title={LocalTime.format_full(@value)}
      {@rest}
    >{LocalTime.format(@value, @style)}</time>
    """
  end
end
