defmodule KanbanWeb.LocalTime.Names do
  @moduledoc """
  Translated month, weekday and AM/PM names for `KanbanWeb.LocalTime`.

  Each function matches the callback shape `Calendar.strftime/3` expects for
  its `:month_names`, `:abbreviated_month_names`, `:day_of_week_names`,
  `:abbreviated_day_of_week_names` and `:am_pm_names` options. Every name is a
  literal `pgettext/2` call so `mix gettext.extract` finds it, and the context
  keeps names that are spelled the same in English ("May", the full and the
  abbreviated month) translatable separately.

  Only names are translated here. The strftime patterns stay code constants in
  `KanbanWeb.LocalTime`, so a translation can never change a format directive.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  The full month name for `month` (1 = January).
  """
  @spec month(1..12) :: String.t()
  def month(1), do: pgettext("month name", "January")
  def month(2), do: pgettext("month name", "February")
  def month(3), do: pgettext("month name", "March")
  def month(4), do: pgettext("month name", "April")
  def month(5), do: pgettext("month name", "May")
  def month(6), do: pgettext("month name", "June")
  def month(7), do: pgettext("month name", "July")
  def month(8), do: pgettext("month name", "August")
  def month(9), do: pgettext("month name", "September")
  def month(10), do: pgettext("month name", "October")
  def month(11), do: pgettext("month name", "November")
  def month(12), do: pgettext("month name", "December")

  @doc """
  The abbreviated month name for `month` (1 = January).
  """
  @spec month_abbr(1..12) :: String.t()
  def month_abbr(1), do: pgettext("month abbreviation", "Jan")
  def month_abbr(2), do: pgettext("month abbreviation", "Feb")
  def month_abbr(3), do: pgettext("month abbreviation", "Mar")
  def month_abbr(4), do: pgettext("month abbreviation", "Apr")
  def month_abbr(5), do: pgettext("month abbreviation", "May")
  def month_abbr(6), do: pgettext("month abbreviation", "Jun")
  def month_abbr(7), do: pgettext("month abbreviation", "Jul")
  def month_abbr(8), do: pgettext("month abbreviation", "Aug")
  def month_abbr(9), do: pgettext("month abbreviation", "Sep")
  def month_abbr(10), do: pgettext("month abbreviation", "Oct")
  def month_abbr(11), do: pgettext("month abbreviation", "Nov")
  def month_abbr(12), do: pgettext("month abbreviation", "Dec")

  @doc """
  The full weekday name for `day` (1 = Monday, as `Date.day_of_week/1`).
  """
  @spec weekday(1..7) :: String.t()
  def weekday(1), do: pgettext("weekday name", "Monday")
  def weekday(2), do: pgettext("weekday name", "Tuesday")
  def weekday(3), do: pgettext("weekday name", "Wednesday")
  def weekday(4), do: pgettext("weekday name", "Thursday")
  def weekday(5), do: pgettext("weekday name", "Friday")
  def weekday(6), do: pgettext("weekday name", "Saturday")
  def weekday(7), do: pgettext("weekday name", "Sunday")

  @doc """
  The abbreviated weekday name for `day` (1 = Monday).
  """
  @spec weekday_abbr(1..7) :: String.t()
  def weekday_abbr(1), do: pgettext("weekday abbreviation", "Mon")
  def weekday_abbr(2), do: pgettext("weekday abbreviation", "Tue")
  def weekday_abbr(3), do: pgettext("weekday abbreviation", "Wed")
  def weekday_abbr(4), do: pgettext("weekday abbreviation", "Thu")
  def weekday_abbr(5), do: pgettext("weekday abbreviation", "Fri")
  def weekday_abbr(6), do: pgettext("weekday abbreviation", "Sat")
  def weekday_abbr(7), do: pgettext("weekday abbreviation", "Sun")

  @doc """
  The before-noon or after-noon marker for a 12-hour clock.
  """
  @spec am_pm(:am | :pm) :: String.t()
  def am_pm(:am), do: pgettext("time of day", "AM")
  def am_pm(:pm), do: pgettext("time of day", "PM")
end
