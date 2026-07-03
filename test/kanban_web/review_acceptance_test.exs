defmodule KanbanWeb.ReviewAcceptanceTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewAcceptance

  describe "acceptance_value/1 — legacy (reviewer not dispatched)" do
    test "returns the bare criterion total when the reviewer never ran" do
      task = %{
        acceptance_criteria: "First\nSecond\nThird",
        reviewer_result: %{},
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_value(task) == "3"
    end

    test "returns nil when there are no acceptance criteria" do
      task = %{acceptance_criteria: "", reviewer_result: %{}, review_report: nil}
      assert ReviewAcceptance.acceptance_value(task) == nil
    end

    test "returns nil when acceptance_criteria is nil" do
      task = %{acceptance_criteria: nil, reviewer_result: %{}, review_report: nil}
      assert ReviewAcceptance.acceptance_value(task) == nil
    end
  end

  describe "acceptance_value/1 — reviewer dispatched" do
    test "renders checked/total with no issues" do
      task = %{
        acceptance_criteria: "A\nB\nC",
        reviewer_result: %{"dispatched" => true, "acceptance_criteria_checked" => 3},
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_value(task) == "3/3"
    end

    test "appends the issue count when structured issues are present" do
      task = %{
        acceptance_criteria: "A\nB\nC",
        reviewer_result: %{
          "dispatched" => true,
          "acceptance_criteria_checked" => 3,
          "issues" => [%{"x" => 1}, %{"y" => 2}]
        },
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_value(task) == "3/3 · 2 issues"
    end

    test "clamps a drifted checked count so it never exceeds the total (W1102)" do
      task = %{
        acceptance_criteria: "A\nB\nC\nD\nE",
        reviewer_result: %{"dispatched" => true, "acceptance_criteria_checked" => 6},
        review_report: nil
      }

      # 6/5 would be impossible; clamp to 5/5.
      assert ReviewAcceptance.acceptance_value(task) == "5/5"
    end
  end

  describe "acceptance_inconsistent?/1 — criterion count drift" do
    test "true when the checked count drifts from the task's criterion count" do
      task = %{
        acceptance_criteria: "A\nB\nC\nD\nE",
        reviewer_result: %{"dispatched" => true, "acceptance_criteria_checked" => 6},
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_inconsistent?(task)
    end

    test "true when the structured acceptance_criteria length disagrees with the total" do
      task = %{
        acceptance_criteria: "A\nB\nC",
        reviewer_result: %{
          "dispatched" => true,
          "acceptance_criteria_checked" => 3,
          "acceptance_criteria" => [%{"status" => "met"}, %{"status" => "met"}]
        },
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_inconsistent?(task)
    end

    test "false when counts agree" do
      task = %{
        acceptance_criteria: "A\nB\nC",
        reviewer_result: %{"dispatched" => true, "acceptance_criteria_checked" => 3},
        review_report: nil
      }

      refute ReviewAcceptance.acceptance_inconsistent?(task)
    end

    test "false when the reviewer was not dispatched" do
      task = %{acceptance_criteria: "A\nB\nC", reviewer_result: %{}, review_report: nil}
      refute ReviewAcceptance.acceptance_inconsistent?(task)
    end
  end

  describe "acceptance_passed/1" do
    test "true for an approved structured status" do
      assert ReviewAcceptance.acceptance_passed(%{reviewer_result: %{"status" => "approved"}}) ==
               true
    end

    test "false for a changes_requested structured status" do
      assert ReviewAcceptance.acceptance_passed(%{
               reviewer_result: %{"status" => "changes_requested"}
             }) == false
    end

    test "false when any structured criterion is not_met" do
      task = %{
        reviewer_result: %{
          "acceptance_criteria" => [%{"status" => "met"}, %{"status" => "not_met"}]
        }
      }

      assert ReviewAcceptance.acceptance_passed(task) == false
    end

    test "true when all structured criteria are met" do
      task = %{
        reviewer_result: %{"acceptance_criteria" => [%{"status" => "met"}, %{"status" => "met"}]}
      }

      assert ReviewAcceptance.acceptance_passed(task) == true
    end

    test "nil for a legacy/thin reviewer_result (never infers from issues_found) (D56)" do
      assert ReviewAcceptance.acceptance_passed(%{
               reviewer_result: %{"dispatched" => true, "issues_found" => 3}
             }) == nil
    end

    test "nil when there is no reviewer_result" do
      assert ReviewAcceptance.acceptance_passed(%{}) == nil
    end
  end

  describe "acceptance_checked/1 and acceptance_failed/1 — status map parsing" do
    setup do
      report = """
      ### Acceptance criteria status

      1. First criterion — Met.
      2. Second criterion — Not Met.
      3. Third criterion — Met.
      """

      %{task: %{acceptance_criteria: "A\nB\nC", reviewer_result: %{}, review_report: report}}
    end

    test "acceptance_checked maps the Met rows (0-based indices)", %{task: task} do
      assert ReviewAcceptance.acceptance_checked(task) == %{0 => true, 2 => true}
    end

    test "acceptance_failed maps the Not Met rows", %{task: task} do
      assert ReviewAcceptance.acceptance_failed(task) == %{1 => true}
    end
  end

  describe "acceptance_checked/1 — fallback when the report has no status section" do
    test "marks all rows checked when the reviewer ran and the bulk count matches" do
      task = %{
        acceptance_criteria: "A\nB\nC",
        reviewer_result: %{"dispatched" => true, "acceptance_criteria_checked" => 3},
        review_report: nil
      }

      assert ReviewAcceptance.acceptance_checked(task) == %{0 => true, 1 => true, 2 => true}
    end

    test "empty when the reviewer did not run" do
      task = %{acceptance_criteria: "A\nB\nC", reviewer_result: %{}, review_report: nil}
      assert ReviewAcceptance.acceptance_checked(task) == %{}
    end

    test "acceptance_failed is empty when the report lacks a status section" do
      task = %{acceptance_criteria: "A\nB\nC", reviewer_result: %{}, review_report: nil}
      assert ReviewAcceptance.acceptance_failed(task) == %{}
    end
  end

  describe "structured_acceptance/1" do
    test "returns the structured list when present" do
      list = [%{"criterion" => "A", "status" => "met"}]

      assert ReviewAcceptance.structured_acceptance(%{
               reviewer_result: %{"acceptance_criteria" => list}
             }) ==
               list
    end

    test "returns [] when absent" do
      assert ReviewAcceptance.structured_acceptance(%{reviewer_result: %{}}) == []
      assert ReviewAcceptance.structured_acceptance(%{}) == []
    end
  end
end
