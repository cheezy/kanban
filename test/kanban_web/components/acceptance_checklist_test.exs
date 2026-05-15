defmodule KanbanWeb.AcceptanceChecklistTest do
  @moduledoc """
  Contract tests for `KanbanWeb.AcceptanceChecklist.acceptance_checklist/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.AcceptanceChecklist

  describe "acceptance_checklist/1 — parsing" do
    test "renders 3 rows for 3 newline-separated lines" do
      assigns = %{
        criteria: """
        Foo passes
        Bar is rendered
        Baz is tested
        """
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ "Foo passes"
      assert html =~ "Bar is rendered"
      assert html =~ "Baz is tested"
      # 3 list items.
      assert length(Regex.scan(~r/<li[^>]*>/, html)) == 3
    end

    test "trims trailing blank lines and ignores empty rows" do
      assigns = %{criteria: "Alpha\n\n\nBeta\n   \n"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ "Alpha"
      assert html =~ "Beta"

      assert length(Regex.scan(~r/<li[^>]*>/, html)) == 2
    end

    test "trims surrounding whitespace from each line" do
      assigns = %{criteria: "  Indented item  \n\tTabbed item\n"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ ">Indented item<"
      assert html =~ ">Tabbed item<"
    end
  end

  describe "acceptance_checklist/1 — empty / nil" do
    test "handles nil input with empty-state message" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={nil} />
        """)

      assert html =~ "data-acceptance-checklist"
      assert html =~ "No acceptance criteria recorded."
      refute html =~ "<li"
    end

    test "handles empty-string input with empty-state message" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria="" />
        """)

      assert html =~ "No acceptance criteria recorded."
      refute html =~ "<li"
    end

    test "handles whitespace-only input with empty-state message" do
      assigns = %{criteria: "   \n\n   "}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ "No acceptance criteria recorded."
      refute html =~ "<li"
    end
  end

  describe "acceptance_checklist/1 — checked state" do
    test "renders the checked style when an index is true" do
      assigns = %{criteria: "First\nSecond", checked: %{0 => true}}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
        />
        """)

      assert html =~ "background: var(--st-done);"
      assert html =~ "hero-check"
    end

    test "renders the unchecked style when no rows are checked" do
      assigns = %{criteria: "Just one"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ "border: 1.5px solid var(--line-strong);"
      refute html =~ "background: var(--st-done);"
    end

    test "supports a line-keyed checked map as well as index-keyed" do
      assigns = %{criteria: "Alpha\nBeta", checked: %{"Beta" => true}}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
        />
        """)

      assert html =~ "background: var(--st-done);"
    end

    test "renders the N/M counter when at least one row exists" do
      assigns = %{criteria: "One\nTwo\nThree", checked: %{0 => true, 2 => true}}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
        />
        """)

      assert html =~ "2/3"
    end

    test "omits the N/M counter on empty state" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={nil} />
        """)

      refute html =~ "0/0"
    end
  end

  describe "acceptance_checklist/1 — markers and scope" do
    test "outermost element carries the data-acceptance-checklist marker" do
      assigns = %{criteria: "Anything"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ ~s(data-acceptance-checklist)
    end

    test "outermost element scopes under .stride-screen" do
      assigns = %{criteria: "Anything"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@criteria} />
        """)

      assert html =~ ~s(class="stride-screen")
    end
  end
end
