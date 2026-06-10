defmodule KanbanWeb.MetricsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsComponents

  describe "legend_swatch/1" do
    test "renders the swatch square in the given color followed by the label" do
      html =
        render_component(&MetricsComponents.legend_swatch/1,
          label: "Done",
          color: "var(--st-done)"
        )

      assert html =~
               "display: inline-flex; align-items: center; gap: 5px; font-size: 11px; color: var(--ink-2);"

      assert html =~ ~s(aria-hidden="true")
      assert html =~ "width: 8px; height: 8px; border-radius: 2px; background: var(--st-done);"
      assert html =~ "Done"
    end

    test "interpolates arbitrary colors" do
      html =
        render_component(&MetricsComponents.legend_swatch/1,
          label: "Agent",
          color: "var(--stride-orange)"
        )

      assert html =~ "background: var(--stride-orange);"
      assert html =~ "Agent"
    end
  end
end
