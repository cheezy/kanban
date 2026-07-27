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

  describe "checklist_count/0" do
    test "returns the bullet count baked from priv/CODE-REVIEW.md" do
      expected =
        "priv/CODE-REVIEW.md"
        |> File.read!()
        |> String.split("\n")
        |> Enum.count(&String.starts_with?(&1, "- "))

      assert ReviewContract.checklist_count() == expected
      assert ReviewContract.checklist_count() > 0
    end
  end

  describe "coverage_shortfall/2 — fail open" do
    test "a nil expected count enforces nothing" do
      # The documented incident: an unreadable checklist must never block every
      # completion. nil in, nil out.
      assert ReviewContract.coverage_shortfall(nil, 0) == nil
    end

    test "a non-positive expected count enforces nothing" do
      assert ReviewContract.coverage_shortfall(0, 0) == nil
      assert ReviewContract.coverage_shortfall(-1, 0) == nil
    end

    test "a readable checklist with an unusable supplied count still reports" do
      # Pre-existing contract, preserved verbatim by the split: fail-open keys
      # off `expected`, not `supplied`. In practice `supplied` is always
      # `length(checks)`, so this shape is unreachable from the validator.
      assert ReviewContract.coverage_shortfall(25, nil) =~ "of the 25 project checklist bullets"
    end
  end

  describe "coverage_shortfall/2 — enforcement" do
    test "full coverage returns nil" do
      assert ReviewContract.coverage_shortfall(25, 25) == nil
    end

    test "over-coverage returns nil" do
      assert ReviewContract.coverage_shortfall(25, 26) == nil
    end

    test "a shortfall returns a message naming both counts" do
      assert ReviewContract.coverage_shortfall(25, 3) ==
               "is incomplete: project_checks covers 3 of the 25 project checklist bullets; every checklist bullet must be evaluated"
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
