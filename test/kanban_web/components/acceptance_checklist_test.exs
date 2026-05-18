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

  describe "acceptance_checklist/1 — failed state" do
    test "renders a red X mark when a row index is in the failed map" do
      assigns = %{criteria: "First\nSecond", failed: %{1 => true}}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          failed={@failed}
        />
        """)

      assert html =~ "hero-x-mark"
      assert html =~ ~s(aria-label="Not met")
    end

    test "supports a line-keyed failed map as well as index-keyed" do
      assigns = %{criteria: "Alpha\nBeta", failed: %{"Beta" => true}}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          failed={@failed}
        />
        """)

      assert html =~ "hero-x-mark"
    end

    test "failed marker takes precedence over checked on the same row" do
      assigns = %{
        criteria: "Conflicting",
        checked: %{0 => true},
        failed: %{0 => true}
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
          failed={@failed}
        />
        """)

      # X mark wins — green check should not appear on the same row.
      assert html =~ "hero-x-mark"
      refute html =~ "hero-check"
    end

    test "mixes checked + failed + unchecked rows in a single render" do
      assigns = %{
        criteria: "Met item\nFailed item\nUntouched item",
        checked: %{0 => true},
        failed: %{1 => true}
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
          failed={@failed}
        />
        """)

      assert html =~ "hero-check"
      assert html =~ "hero-x-mark"
      # The unchecked row still renders its empty box (no icon, just border).
      assert html =~ "border: 1.5px solid var(--line-strong);"
    end

    test "N/M counter only counts checked rows (failed rows do not increment)" do
      assigns = %{
        criteria: "One\nTwo\nThree",
        checked: %{0 => true},
        failed: %{1 => true, 2 => true}
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          checked={@checked}
          failed={@failed}
        />
        """)

      # Only the one checked row counts toward the counter.
      assert html =~ "1/3"
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
