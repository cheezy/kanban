defmodule KanbanWeb.SectionHeadTest do
  @moduledoc """
  Contract tests for `KanbanWeb.SectionHead.section_head/1` — the inline
  section title used in the task-detail pane body.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.SectionHead

  describe "section_head/1 — base" do
    test "renders the title with the data-section-head marker" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHead.section_head title="Key files" />
        """)

      assert html =~ "data-section-head"
      assert html =~ ~r/>\s*Key files\s*</
    end

    test "applies the canonical 12px bold typography" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHead.section_head title="Pitfalls" />
        """)

      assert html =~ "font-size: 12px"
      assert html =~ "font-weight: 600"
    end

    test "renders without a count label by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHead.section_head title="History" />
        """)

      refute html =~ ~s(class="ident")
    end
  end

  describe "section_head/1 — count_label" do
    test "renders the count label after the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHead.section_head title="Acceptance criteria" count_label="0/6" />
        """)

      assert html =~ "Acceptance criteria"
      assert html =~ "0/6"
      assert html =~ ~s(class="ident")
    end

    test "renders longer narrative count labels" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionHead.section_head
          title="Key files"
          count_label="6 · locked while claimed"
        />
        """)

      assert html =~ "6 · locked while claimed"
    end
  end
end
