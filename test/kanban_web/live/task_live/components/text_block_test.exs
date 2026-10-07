defmodule KanbanWeb.TaskLive.Components.TextBlockTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.TextBlock

  test "renders the label and the text in the sans font by default" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <TextBlock.block label="Why">Because</TextBlock.block>
      """)

    assert html =~ "Why"
    assert html =~ "Because"
    assert html =~ "font-family: var(--font-sans);"
    assert html =~ "white-space: pre-wrap;"
  end

  test "uses the mono font when mono is set" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <TextBlock.block label="Where" mono>lib/kanban.ex</TextBlock.block>
      """)

    assert html =~ "font-family: var(--font-mono);"
    refute html =~ "var(--font-sans)"
  end
end
