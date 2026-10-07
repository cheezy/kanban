defmodule KanbanWeb.MetricsLive.Components.Icon do
  @moduledoc """
  The icon helper shared by the metrics page components: a bare `<span>`
  carrying the icon name and any extra classes, so a `hero-*` name renders
  through the Heroicons CSS. Unlike `KanbanWeb.CoreComponents.icon/1` it
  accepts any name, not only `hero-*` ones.

  Split from `KanbanWeb.MetricsLive.Components`, where it was a private
  helper, so `KanbanWeb.MetricsLive.Components` and the component modules
  split from it can all import it. It is not imported into the metrics
  LiveViews, which use the core `icon/1`.
  """
  use Phoenix.Component

  @doc """
  Renders an icon as a `<span>` whose classes are the icon name and `class`.
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
