defmodule KanbanWeb.ReviewReportHelpers.TokensTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers.Tokens

  describe "review_status_pill/1 (moved from ReviewLive, W1441)" do
    test "approved status renders the approved pill" do
      pill = Tokens.review_status_pill(%{reviewer_result: %{"status" => "approved"}})
      assert pill.status == "approved"
      assert pill.icon == "hero-check-circle"
      assert pill.style =~ "--st-done"
    end

    test "changes_requested status renders the changes-requested pill" do
      pill =
        Tokens.review_status_pill(%{
          reviewer_result: %{"status" => "changes_requested"}
        })

      assert pill.status == "changes_requested"
      assert pill.icon == "hero-arrow-uturn-left"
      assert pill.style =~ "--st-blocked"
    end

    test "dispatched-but-no-status renders the neutral unavailable pill (D56)" do
      pill = Tokens.review_status_pill(%{reviewer_result: %{"dispatched" => true}})
      assert pill.status == "unavailable"
      assert pill.icon == "hero-question-mark-circle"
    end

    test "returns nil when the reviewer was skipped/never ran" do
      assert Tokens.review_status_pill(%{reviewer_result: %{}}) == nil
      assert Tokens.review_status_pill(%{}) == nil
    end
  end

  describe "verdict_tone_style/1 and verdict_icon/2 (moved from ReviewLive, W1441)" do
    test "tone style is green for true, red for false, neutral otherwise" do
      assert Tokens.verdict_tone_style(true) =~ "--st-done"
      assert Tokens.verdict_tone_style(false) =~ "--st-blocked"
      assert Tokens.verdict_tone_style(nil) =~ "--surface-2"
    end

    test "security section keeps shield iconography" do
      assert Tokens.verdict_icon(:security_considerations, false) ==
               "hero-shield-exclamation"

      assert Tokens.verdict_icon(:security_considerations, true) ==
               "hero-shield-check"
    end

    test "generic sections use pass/fail/unknown circles" do
      assert Tokens.verdict_icon(:testing_strategy, true) == "hero-check-circle"
      assert Tokens.verdict_icon(:patterns, false) == "hero-x-circle"
      assert Tokens.verdict_icon(:pitfalls, nil) == "hero-question-mark-circle"
    end
  end

  describe "category_status_key/1 and category_verdict_label/1 (moved from ReviewLive, W1441)" do
    test "status key maps the boolean verdict" do
      assert Tokens.category_status_key(true) == "passed"
      assert Tokens.category_status_key(false) == "failed"
      assert Tokens.category_status_key(nil) == "not_assessed"
    end

    test "verdict label maps the boolean verdict" do
      assert Tokens.category_verdict_label(true) == "passed"
      assert Tokens.category_verdict_label(false) == "failed"
      assert Tokens.category_verdict_label(nil) == "not assessed"
    end
  end

  describe "section_status_key/1 and review_check_rows/1 (moved from ReviewLive, W1441)" do
    test "section_status_key reflects the section verdict" do
      passed = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "passed"}},
        review_report: nil
      }

      failed = %{
        reviewer_result: %{"testing_strategy" => %{"status" => "failed"}},
        review_report: nil
      }

      absent = %{reviewer_result: %{}, review_report: nil}

      assert Tokens.section_status_key(passed, :testing_strategy) == "passed"
      assert Tokens.section_status_key(failed, :testing_strategy) == "failed"
      assert Tokens.section_status_key(absent, :testing_strategy) == "not_assessed"
    end

    test "review_check_rows returns rows for sections with a value and none for a legacy task" do
      task = %{
        reviewer_result: %{
          "testing_strategy" => %{"status" => "passed"},
          "patterns" => %{"status" => "passed"}
        },
        review_report: nil
      }

      rows = Tokens.review_check_rows(task)
      assert Enum.any?(rows, &(&1.section == :testing_strategy and &1.status == "passed"))

      empty = %{reviewer_result: %{}, review_report: nil}
      assert Tokens.review_check_rows(empty) == []
    end
  end
end
