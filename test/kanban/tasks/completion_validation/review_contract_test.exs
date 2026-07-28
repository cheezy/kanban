defmodule Kanban.Tasks.CompletionValidation.ReviewContractTest do
  @moduledoc """
  Direct unit tests for the always-reject review completeness contract (W1953).

  The contract's rejections are covered end to end through the parent's
  `review_contract_failures/2` delegate in completion_validation_test.exs. This
  file pins what that cannot see: `check_structured_block/4`'s short-circuit
  clauses and accumulator contract, and the fail-open coverage decision — the
  branch that must never start blocking completions.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CompletionValidation.ReviewContract

  describe "sections/0" do
    test "is the canonical required-section list" do
      sections = ReviewContract.sections()

      assert is_list(sections)
      assert :issues in sections
      assert :project_checks in sections
      assert Enum.all?(sections, &is_atom/1)
    end
  end

  # Regression guard for the cross-tenant defect: the contract must never
  # measure a caller's project_checks against a checklist size the server
  # invented. Any list length is acceptable, including zero.
  describe "project_checks length is never gated" do
    @dispatched_sections %{
      "dispatched" => true,
      "issues" => [],
      "acceptance_criteria" => [],
      "testing_strategy" => %{"status" => "passed"},
      "patterns" => %{"status" => "passed"},
      "pitfalls" => %{"status" => "passed"},
      "security_considerations" => %{"status" => "passed"},
      "schema_version" => "1.6",
      "status" => "approved"
    }

    test "no checklist length produces a project_checks failure" do
      for count <- [0, 1, 3, 9, 25, 40] do
        checks = for i <- 1..count//1, do: %{"check" => "c#{i}", "status" => "met"}
        result = Map.put(@dispatched_sections, "project_checks", checks)

        failures = ReviewContract.failures(result)

        refute Enum.any?(failures, fn {field, _} -> field == :project_checks end),
               "a #{count}-entry project_checks must not be rejected on length"
      end
    end

    test "a present-but-non-list project_checks is still rejected" do
      result = Map.put(@dispatched_sections, "project_checks", "nine checks")

      failures =
        result
        |> ReviewContract.failures()
        |> Enum.filter(fn {field, _} -> field == :project_checks end)

      assert [{:project_checks, message}] = failures
      assert message =~ "list"
    end
  end

  describe "check_structured_block/4 — short circuits" do
    @complete %{"dispatched" => true}

    test "a non-reviewer role is not checked" do
      assert ReviewContract.check_structured_block([], @complete, :explorer,
               require_structured_block: true
             ) == []
    end

    test "a review that was not dispatched is not checked" do
      assert ReviewContract.check_structured_block([], %{"dispatched" => false}, :reviewer,
               require_structured_block: true
             ) == []
    end

    test "opting out of the strict block skips the check" do
      assert ReviewContract.check_structured_block([], @complete, :reviewer, []) == []
    end
  end

  describe "check_structured_block/4 — accumulator contract" do
    test "pre-existing errors pass through and new failures are prepended" do
      seeded = [{:earlier, "first"}]

      errors =
        ReviewContract.check_structured_block(seeded, %{"dispatched" => true}, :reviewer,
          require_structured_block: true
        )

      assert List.last(errors) == {:earlier, "first"}
      assert length(errors) > 1
    end
  end

  describe "failures/2" do
    test "a review that was not dispatched has no failures" do
      assert ReviewContract.failures(%{"dispatched" => false}, nil) == []
    end

    test "a nil task runs only the structural checks" do
      failures = ReviewContract.failures(%{"dispatched" => true}, nil)

      assert Enum.any?(failures, fn {field, _} -> field == :issues end)
    end

    test "failures come back in report order, not reversed" do
      failures = ReviewContract.failures(%{"dispatched" => true}, nil)
      fields = Enum.map(failures, fn {field, _} -> field end)

      # The required sections come first, in sections/0 order — the order the
      # review queue renders them in — followed by the either/or and
      # schema_version checks. A reversed accumulator would invert this.
      section_fields = Enum.filter(fields, &(&1 in ReviewContract.sections()))
      assert section_fields == Enum.filter(ReviewContract.sections(), &(&1 in fields))
      assert List.first(fields) == List.first(ReviewContract.sections())
    end
  end
end
