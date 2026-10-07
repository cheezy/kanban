defmodule KanbanWeb.AgentsLive.Components.LiveIndicatorTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.AgentsLive.Components.LiveIndicator

  test "renders the live label and the connected count" do
    html = render_component(&LiveIndicator.live_indicator/1, connected_count: 3)

    assert html =~ "data-agents-live-indicator"
    assert html =~ ~r/>\s*live\s*</
    assert html =~ "3 connected"
  end

  test "renders a single viewer and no viewers" do
    assert render_component(&LiveIndicator.live_indicator/1, connected_count: 1) =~
             "1 connected"

    assert render_component(&LiveIndicator.live_indicator/1, connected_count: 0) =~
             "0 connected"
  end
end
