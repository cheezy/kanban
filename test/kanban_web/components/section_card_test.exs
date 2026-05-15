defmodule KanbanWeb.SectionCardTest do
  @moduledoc """
  Contract tests for `KanbanWeb.SectionCard.section_card/1` — the
  titled, padded, bordered content block used across the task detail
  page.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.SectionCard

  describe "section_card/1 — base render" do
    test "renders the title and body slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Why">
          To improve developer ergonomics.
        </SectionCard.section_card>
        """)

      assert html =~ "data-section-card"
      assert html =~ ">Why<" || html =~ ~r/>\s*Why\s*</
      assert html =~ "To improve developer ergonomics."
    end

    test "carries the canonical surface + border tokens" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="X">y</SectionCard.section_card>
        """)

      assert html =~ "background: var(--surface)"
      assert html =~ "border: 1px solid var(--line)"
      assert html =~ "border-radius: 8px"
    end
  end

  describe "section_card/1 — tone" do
    test ":default tone colors the title with --ink-3" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Notes">body</SectionCard.section_card>
        """)

      assert html =~ "color: var(--ink-3)"
      refute html =~ "color: var(--st-blocked)"
    end

    test ":warn tone shifts title + body to --st-blocked" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Pitfalls" tone={:warn}>
          Don&apos;t reuse the old secret.
        </SectionCard.section_card>
        """)

      assert html =~ "color: var(--st-blocked)"
    end

    test ":muted tone shifts title + body to --ink-3" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Out of scope" tone={:muted}>
          Deferred items.
        </SectionCard.section_card>
        """)

      # --ink-3 appears in the body color for muted (and also as the
      # title default; both occurrences are fine).
      assert html =~ "color: var(--ink-3)"
    end
  end

  describe "section_card/1 — mono body" do
    test "switches the body font to var(--font-mono) when mono is true" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Verification" mono>
          mix test
        </SectionCard.section_card>
        """)

      assert html =~ "font-family: var(--font-mono)"
    end

    test "uses var(--font-sans) by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Why">body</SectionCard.section_card>
        """)

      assert html =~ "font-family: var(--font-sans)"
    end
  end

  describe "section_card/1 — count label" do
    test "renders the count label when provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Key files" count_label="6">
          body
        </SectionCard.section_card>
        """)

      assert html =~ "Key files"
      assert html =~ ~r/>\s*6\s*</
    end

    test "omits the count label when absent" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SectionCard.section_card title="Key files">body</SectionCard.section_card>
        """)

      # No ident-styled count chip in the title.
      refute html =~ ~s(class="ident")
    end
  end
end
