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

  describe "acceptance_checklist/1 — structured (reviewer_result.acceptance_criteria)" do
    test "non-empty `structured` list switches to the structured renderer" do
      assigns = %{
        structured: [
          %{"criterion" => "Met one", "status" => "met", "evidence" => "lib/a.ex:10"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ ~s(data-acceptance-checklist-mode="structured")
      assert html =~ "data-acceptance-checklist-row"
      assert html =~ ~s(data-acceptance-checklist-status="met")
      assert html =~ "Met one"
    end

    test "renders the red X + evidence under a not_met row" do
      assigns = %{
        structured: [
          %{
            "criterion" => "PubSub broadcast emitted exactly once per move",
            "status" => "not_met",
            "evidence" => "lib/kanban/tasks.ex:172 broadcasts twice — see the critical issue."
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ ~s(data-acceptance-checklist-status="not_met")
      assert html =~ "hero-x-mark"
      assert html =~ "data-acceptance-checklist-evidence"
      assert html =~ "broadcasts twice"
      # Evidence on not_met rows uses the blocked/red ink.
      assert html =~ "var(--st-blocked"
    end

    test "renders evidence in muted style for met rows" do
      assigns = %{
        structured: [
          %{"criterion" => "Works", "status" => "met", "evidence" => "lib/a.ex:10-20"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "lib/a.ex:10-20"
      # Met rows render evidence in --ink-3 (muted), not the blocked red.
      assert html =~ "color: var(--ink-3)"
    end

    test "header counter reflects met/total for structured rows" do
      assigns = %{
        structured: [
          %{"criterion" => "A", "status" => "met", "evidence" => "x"},
          %{"criterion" => "B", "status" => "met", "evidence" => "y"},
          %{"criterion" => "C", "status" => "not_met", "evidence" => "z"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "2/3"
    end

    test "empty `structured` list falls back to the legacy unstructured renderer" do
      assigns = %{criteria: "Alpha\nBeta"}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist
          acceptance_criteria={@criteria}
          structured={[]}
        />
        """)

      assert html =~ "Alpha"
      assert html =~ "Beta"
      refute html =~ "data-acceptance-checklist-mode"
      refute html =~ "data-acceptance-checklist-row"
    end

    test "omits the evidence paragraph when not_met has no evidence text" do
      assigns = %{
        structured: [
          %{"criterion" => "No evidence", "status" => "not_met", "evidence" => nil}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ ~s(data-acceptance-checklist-status="not_met")
      refute html =~ "data-acceptance-checklist-evidence"
    end
  end

  describe "acceptance_checklist/1 — pending commit (D304)" do
    # The reviewer opens a scheduled-commit row's evidence with this exact
    # sentinel. EM DASH (U+2014), trailing space — a hyphen must not match.
    @sentinel "PENDING COMMIT — "

    defp pending_row(criterion \\ "The fix is committed") do
      %{
        "criterion" => criterion,
        "status" => "not_met",
        "evidence" => @sentinel <> "the operator's commit, made after this review."
      }
    end

    test "a not_met row with sentinel evidence renders pending, not the failed box" do
      assigns = %{structured: [pending_row()]}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ ~s(data-acceptance-checklist-pending="true")
      assert html =~ "hero-clock"
      # The whole point: no red failure treatment on this row.
      refute html =~ "hero-x-mark"
      refute html =~ "var(--st-blocked"
      # It is still not met — the status attribute is unchanged.
      assert html =~ ~s(data-acceptance-checklist-status="not_met")
    end

    test "the pending state is visibly labelled, not merely unstyled" do
      assigns = %{structured: [pending_row()]}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "data-acceptance-checklist-pending-label"
      assert html =~ "Pending"
      # Amber pending pair, both halves of which carry dark-mode overrides.
      assert html =~ "var(--st-doing-soft)"
      assert html =~ "var(--st-doing)"
      # A soft-filled chip must be delineated by a border (dark-mode contract).
      assert html =~ "border: 1px solid var(--line)"
    end

    test "the header tally reports pending rows separately from failures" do
      assigns = %{
        structured: [
          %{"criterion" => "A", "status" => "met", "evidence" => nil},
          %{"criterion" => "B", "status" => "met", "evidence" => nil},
          pending_row("C")
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      # The numerator is untouched — a pending row is scheduled, not met.
      assert html =~ "2/3"
      assert html =~ "data-acceptance-checklist-pending-tally"
      assert html =~ "(1 pending)"
    end

    test "the tally suffix is omitted entirely when nothing is pending" do
      assigns = %{
        structured: [
          %{"criterion" => "A", "status" => "met", "evidence" => nil},
          %{"criterion" => "B", "status" => "not_met", "evidence" => "genuinely broken"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      refute html =~ "data-acceptance-checklist-pending-tally"
      refute html =~ "pending)"
    end

    test "an ordinary not_met row is untouched and still renders as a failure" do
      assigns = %{
        structured: [
          %{"criterion" => "X", "status" => "not_met", "evidence" => "lib/a.ex:10 is wrong"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "hero-x-mark"
      assert html =~ "var(--st-blocked"
      refute html =~ ~s(data-acceptance-checklist-pending="true")
      refute html =~ "data-acceptance-checklist-pending-label"
    end

    test "the sentinel is honoured only in the reserved leading position" do
      assigns = %{
        structured: [
          %{
            "criterion" => "Y",
            "status" => "not_met",
            "evidence" => "the reviewer wrote " <> @sentinel <> "in the middle of a sentence"
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      # A substring match here would let a genuine failure disguise itself.
      refute html =~ ~s(data-acceptance-checklist-pending="true")
      assert html =~ "hero-x-mark"
    end

    test "an ASCII hyphen in place of the em dash does not match" do
      assigns = %{
        structured: [
          %{
            "criterion" => "Z",
            "status" => "not_met",
            "evidence" => "PENDING COMMIT - the operator's commit, with a hyphen."
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      refute html =~ ~s(data-acceptance-checklist-pending="true")
      assert html =~ "hero-x-mark"
    end

    test "a met row whose evidence merely contains the sentinel is unaffected" do
      assigns = %{
        structured: [
          %{"criterion" => "W", "status" => "met", "evidence" => @sentinel <> "irrelevant here"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "hero-check"
      refute html =~ ~s(data-acceptance-checklist-pending="true")
    end

    test "nil and empty evidence never raise and never read as pending" do
      for evidence <- [nil, ""] do
        assigns = %{
          structured: [%{"criterion" => "V", "status" => "not_met", "evidence" => evidence}]
        }

        html =
          rendered_to_string(~H"""
          <AcceptanceChecklist.acceptance_checklist structured={@structured} />
          """)

        refute html =~ ~s(data-acceptance-checklist-pending="true")
        assert html =~ "hero-x-mark"
      end
    end

    test "several pending rows in one review are counted together" do
      assigns = %{
        structured: [
          %{"criterion" => "A", "status" => "met", "evidence" => nil},
          pending_row("B"),
          pending_row("C")
        ]
      }

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "1/3"
      assert html =~ "(2 pending)"
    end

    test "pending evidence renders in muted ink rather than the blocked red" do
      assigns = %{structured: [pending_row()]}

      html =
        rendered_to_string(~H"""
        <AcceptanceChecklist.acceptance_checklist structured={@structured} />
        """)

      assert html =~ "data-acceptance-checklist-evidence"
      assert html =~ "the operator&#39;s commit"
      assert html =~ "var(--ink-3)"
      refute html =~ "var(--st-blocked"
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
