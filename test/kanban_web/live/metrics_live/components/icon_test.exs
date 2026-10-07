defmodule KanbanWeb.MetricsLive.Components.IconTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsLive.Components.Icon

  test "renders a span whose classes are the icon name and the extra class" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Icon.icon name="hero-clock" class="h-4 w-4" />
      """)

    assert html =~ ~s(<span class="hero-clock h-4 w-4"></span>)
  end

  test "renders only the icon name when no class is given" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Icon.icon name="hero-funnel-solid" />
      """)

    assert html =~ ~s(<span class="hero-funnel-solid"></span>)
  end

  test "accepts a name that is not a hero icon" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Icon.icon name="custom-icon" />
      """)

    assert html =~ ~s(<span class="custom-icon"></span>)
  end
end
