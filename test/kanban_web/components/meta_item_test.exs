defmodule KanbanWeb.MetaItemTest do
  @moduledoc """
  Contract tests for `KanbanWeb.MetaItem.meta_item/1` — the label/value
  block used in the task-detail right rail.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetaItem

  describe "meta_item/1 — base" do
    test "renders the UCASE label and the slot value" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MetaItem.meta_item label="Author">
          <span>Jamie</span>
        </MetaItem.meta_item>
        """)

      assert html =~ "data-meta-item"
      assert html =~ ~s(class="ucase")
      assert html =~ "Author"
      assert html =~ "Jamie"
    end

    test "applies the small 9.5px UCASE label style" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MetaItem.meta_item label="Goal">G7</MetaItem.meta_item>
        """)

      assert html =~ "font-size: 9.5px"
    end
  end

  describe "meta_item/1 — mono" do
    test "switches the value font to var(--font-mono) when mono is true" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MetaItem.meta_item label="Telemetry" mono>
          [:kanban, :auth]
        </MetaItem.meta_item>
        """)

      assert html =~ "font-family: var(--font-mono)"
    end

    test "uses var(--font-sans) by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <MetaItem.meta_item label="Status">Open</MetaItem.meta_item>
        """)

      assert html =~ "font-family: var(--font-sans)"
    end
  end
end
