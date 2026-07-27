defmodule Kanban.Tasks.CompletionValidation.AcceptanceCountsTest do
  @moduledoc """
  Direct unit tests for the grace-gated acceptance-criteria count agreement
  (W1953).

  The count rules are exercised through the parent's
  `acceptance_criteria_count_failures/2` delegate in
  completion_validation_test.exs. This file pins the short-circuits — the
  shapes that must contribute NO failure rather than raise — because a
  malformed payload reaching this rule must fall through to the shape
  validator, not blow up the completion request.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation.AcceptanceCounts

  defp task(criteria), do: %{acceptance_criteria: criteria}

  describe "failures/2 — not applicable" do
    test "a nil task yields no failures" do
      assert AcceptanceCounts.failures(%{"dispatched" => true}, nil) == []
    end

    test "a review that was not dispatched yields no failures" do
      review = %{"dispatched" => false, "acceptance_criteria_checked" => 99}
      assert AcceptanceCounts.failures(review, task("one\ntwo")) == []
    end

    test "a task defining no criteria yields no failures" do
      review = %{"dispatched" => true, "acceptance_criteria_checked" => 99}

      assert AcceptanceCounts.failures(review, task(nil)) == []
      assert AcceptanceCounts.failures(review, task("")) == []
      assert AcceptanceCounts.failures(review, task("   \n  ")) == []
    end
  end

  describe "failures/2 — malformed shapes fall through" do
    test "a non-list acceptance_criteria contributes no count failure" do
      review = %{"dispatched" => true, "acceptance_criteria" => "not a list"}
      assert AcceptanceCounts.failures(review, task("one\ntwo")) == []
    end

    test "a non-integer acceptance_criteria_checked contributes no count failure" do
      review = %{"dispatched" => true, "acceptance_criteria_checked" => "two"}
      assert AcceptanceCounts.failures(review, task("one\ntwo")) == []
    end

    test "neither field present contributes no count failure" do
      assert AcceptanceCounts.failures(%{"dispatched" => true}, task("one\ntwo")) == []
    end
  end

  describe "failures/2 — agreement" do
    test "matching counts yield no failures" do
      review = %{
        "dispatched" => true,
        "acceptance_criteria" => [%{}, %{}],
        "acceptance_criteria_checked" => 2
      }

      assert AcceptanceCounts.failures(review, task("one\ntwo")) == []
    end

    test "an over-count is flagged — the W1099 gap cross_check/2 misses" do
      review = %{"dispatched" => true, "acceptance_criteria" => [%{}, %{}, %{}]}

      assert [{:acceptance_criteria, message}] =
               AcceptanceCounts.failures(review, task("one\ntwo"))

      assert message =~ "the review lists 3 acceptance-criteria entries but the task defines 2"
    end

    test "an under-count is flagged too" do
      review = %{"dispatched" => true, "acceptance_criteria" => [%{}]}

      assert [{:acceptance_criteria, message}] =
               AcceptanceCounts.failures(review, task("one\ntwo"))

      assert message =~ "the review lists 1 acceptance-criteria entries but the task defines 2"
    end

    test "the legacy checked integer is compared independently" do
      review = %{"dispatched" => true, "acceptance_criteria_checked" => 5}

      assert [{:acceptance_criteria_checked, message}] =
               AcceptanceCounts.failures(review, task("one\ntwo"))

      assert message =~ "the review reports 5 acceptance criteria checked but the task defines 2"
    end

    test "both fields disagreeing report both failures" do
      review = %{
        "dispatched" => true,
        "acceptance_criteria" => [%{}],
        "acceptance_criteria_checked" => 5
      }

      failures = AcceptanceCounts.failures(review, task("one\ntwo"))

      assert Enum.map(failures, &elem(&1, 0)) ==
               [:acceptance_criteria, :acceptance_criteria_checked]
    end

    test "blank criterion lines are not counted" do
      review = %{"dispatched" => true, "acceptance_criteria" => [%{}, %{}]}
      assert AcceptanceCounts.failures(review, task("one\n\n  \ntwo")) == []
    end
  end
end
