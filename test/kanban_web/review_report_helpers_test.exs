defmodule KanbanWeb.ReviewReportHelpersTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers

  describe "structured-field source" do
    test "testing_strategy_value prefers reviewer_result.testing_strategy.status" do
      task = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}},
        review_report: nil
      }

      assert ReviewReportHelpers.testing_strategy_value(task) == "passed"
    end

    test "testing_strategy_passed reflects structured status" do
      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "passed"}}
             }) == true

      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "failed"}}
             }) == false

      assert ReviewReportHelpers.testing_strategy_passed(%{
               reviewer_result: %{"testing_strategy" => %{"status" => "not_assessed"}}
             }) == nil
    end

    test "patterns_value prefers structured status over regex" do
      task = %{
        reviewer_result: %{"patterns" => %{"status" => "failed"}},
        review_report: "### Patterns followed\n\nUsed existing pattern."
      }

      assert ReviewReportHelpers.patterns_value(task) == "failed"
      assert ReviewReportHelpers.patterns_passed(task) == false
    end

    test "pitfalls_value prefers structured status over regex" do
      task = %{
        reviewer_result: %{"pitfalls" => %{"status" => "passed"}},
        review_report: "### Pitfalls\n\nNone violated."
      }

      assert ReviewReportHelpers.pitfalls_value(task) == "passed"
      assert ReviewReportHelpers.pitfalls_passed(task) == true
    end
  end

  describe "regex fallback when no structured field" do
    test "testing_strategy_value falls back to regex when reviewer_result lacks the field" do
      task = %{
        reviewer_result: nil,
        review_report: """
        ### Required test cases (all present)

        - Handles login
        - Handles logout
        """
      }

      assert ReviewReportHelpers.testing_strategy_value(task) =~ "cases · all present"
      assert ReviewReportHelpers.testing_strategy_passed(task) == true
    end

    test "patterns_value falls back to 'followed' regex" do
      task = %{
        reviewer_result: nil,
        review_report: "### Patterns followed\n\nUsed standard pattern."
      }

      assert ReviewReportHelpers.patterns_value(task) == "followed"
      assert ReviewReportHelpers.patterns_passed(task) == true
    end

    test "pitfalls_value falls back to regex" do
      task_clean = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nNone violated."
      }

      task_dirty = %{
        reviewer_result: nil,
        review_report: "### Pitfalls\n\nTwo pitfalls violated."
      }

      assert ReviewReportHelpers.pitfalls_value(task_clean) == "none violated"
      assert ReviewReportHelpers.pitfalls_passed(task_clean) == true
      assert ReviewReportHelpers.pitfalls_value(task_dirty) == "violated"
      assert ReviewReportHelpers.pitfalls_passed(task_dirty) == false
    end

    test "all helpers return nil when neither source is present" do
      task = %{reviewer_result: nil, review_report: nil}

      assert ReviewReportHelpers.testing_strategy_value(task) == nil
      assert ReviewReportHelpers.testing_strategy_passed(task) == nil
      assert ReviewReportHelpers.patterns_value(task) == nil
      assert ReviewReportHelpers.patterns_passed(task) == nil
      assert ReviewReportHelpers.pitfalls_value(task) == nil
      assert ReviewReportHelpers.pitfalls_passed(task) == nil
    end
  end

  describe "report_section/2" do
    test "extracts the section body when present" do
      task = %{review_report: "## Title\n\nbody text"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == "body text"
    end

    test "returns nil when section is absent" do
      task = %{review_report: "## Other\n\nbody"}

      assert ReviewReportHelpers.report_section(task, ~r/title/i) == nil
    end

    test "returns nil when review_report is nil" do
      assert ReviewReportHelpers.report_section(%{review_report: nil}, ~r/title/i) == nil
    end
  end
end
