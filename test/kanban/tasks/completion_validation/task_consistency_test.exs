defmodule Kanban.Tasks.CompletionValidation.TaskConsistencyTest do
  @moduledoc """
  Direct unit tests for the completion/task consistency rules (W1448). These
  rules are also exercised through the `CompletionValidation.cross_check_reviewer_result/2`
  delegate in completion_validation_test.exs; this file pins the module's own
  contract — the acceptance branch and each mismatch branch — with verbatim
  error messages.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation.TaskConsistency

  @security_msg "must be a real assessment: the task supplied security_considerations, so the review must record a passed/failed verdict for it, not not_assessed or absent"
  @testing_msg "must be a real assessment: the task supplied testing_strategy, so the review must record a passed/failed verdict for it, not not_assessed or absent"

  describe "cross_check/2 — pass-through" do
    test "a non-dispatched (skip-form) review passes through untouched" do
      result = %{"dispatched" => false}

      assert TaskConsistency.cross_check(result, %{security_considerations: ["s"]}) ==
               {:ok, result}
    end

    test "a review with no dispatched key passes through untouched" do
      result = %{"reason" => "trivial"}

      assert TaskConsistency.cross_check(result, %{security_considerations: ["s"]}) ==
               {:ok, result}
    end

    test "a dispatched review that assesses everything the task asked about is accepted" do
      task = %{
        security_considerations: ["Keep board scoping intact"],
        testing_strategy: %{"unit_tests" => "cover it"},
        acceptance_criteria: "line one\nline two"
      }

      result = %{
        "dispatched" => true,
        "security_considerations" => %{"status" => "passed"},
        "testing_strategy" => %{"status" => "failed"},
        "acceptance_criteria" => [%{"criterion" => "a"}, %{"criterion" => "b"}]
      }

      assert TaskConsistency.cross_check(result, task) == {:ok, result}
    end
  end

  describe "cross_check/2 — section mismatch branches" do
    test "flags security_considerations left not_assessed when the task supplied it" do
      task = %{security_considerations: ["Keep board scoping intact"], testing_strategy: %{}}
      result = %{"dispatched" => true, "security_considerations" => %{"status" => "not_assessed"}}

      assert {:error, [{:security_considerations, msg}]} =
               TaskConsistency.cross_check(result, task)

      assert msg == @security_msg
    end

    test "flags testing_strategy entirely absent from the report when the task supplied it" do
      task = %{security_considerations: [], testing_strategy: %{"unit_tests" => "x"}}
      result = %{"dispatched" => true}

      assert {:error, [{:testing_strategy, msg}]} = TaskConsistency.cross_check(result, task)
      assert msg == @testing_msg
    end

    test "flags an acceptance-criteria shortfall with the exact counts" do
      task = %{acceptance_criteria: "one\ntwo\nthree"}
      result = %{"dispatched" => true, "acceptance_criteria" => [%{"criterion" => "one"}]}

      assert {:error, [{:acceptance_criteria, msg}]} = TaskConsistency.cross_check(result, task)

      assert msg ==
               "is incomplete: the review checked 1 of the task's 3 acceptance criteria; every acceptance criterion must be assessed"
    end

    test "accumulates every failing rule in section order (security, testing, acceptance)" do
      task = %{
        security_considerations: ["s"],
        testing_strategy: %{"unit_tests" => "x"},
        acceptance_criteria: "a\nb"
      }

      result = %{"dispatched" => true}

      assert {:error,
              [{:security_considerations, _}, {:testing_strategy, _}, {:acceptance_criteria, _}]} =
               TaskConsistency.cross_check(result, task)
    end
  end

  describe "cross_check/2 — supplied? skip behavior" do
    test "skips a section the task left empty ([] / empty map / blank string)" do
      task = %{security_considerations: [], testing_strategy: %{}, acceptance_criteria: ""}
      # No verdicts at all, but nothing was supplied, so nothing is enforced.
      result = %{"dispatched" => true}

      assert TaskConsistency.cross_check(result, task) == {:ok, result}
    end

    test "treats a map with a non-empty value as supplied (enforces the verdict)" do
      task = %{testing_strategy: %{"coverage_target" => "95%"}}
      result = %{"dispatched" => true, "testing_strategy" => %{"status" => "not_assessed"}}

      assert {:error, [{:testing_strategy, _}]} = TaskConsistency.cross_check(result, task)
    end

    test "treats a list of only-blank strings as not supplied" do
      task = %{security_considerations: ["", "   "]}
      result = %{"dispatched" => true}

      assert TaskConsistency.cross_check(result, task) == {:ok, result}
    end
  end
end
