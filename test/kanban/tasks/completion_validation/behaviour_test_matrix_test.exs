defmodule Kanban.Tasks.CompletionValidation.BehaviourTestMatrixTest do
  @moduledoc """
  Direct unit tests for the behaviour_test_matrix verdict validator (W1953).

  The row rules themselves are covered through the parent's public API in
  completion_validation_test.exs. What that file cannot observe is `check/2`'s
  **accumulator contract** — it always sees the final reversed error list, so
  the prepend-and-do-not-reverse behaviour a future caller could break is
  invisible from outside. That is what this file pins, along with the
  pass-through branches that must stay silent.
  """
  use ExUnit.Case, async: true

  alias Kanban.Schemas.Task.BehaviourTestRow
  alias Kanban.Tasks.CompletionValidation.BehaviourTestMatrix

  describe "statuses/0" do
    test "is the row status enum, as atoms" do
      assert BehaviourTestMatrix.statuses() == [:planned, :passing, :failing, :not_applicable]
    end

    test "stays in lockstep with the persisted row schema" do
      # The family is deliberately Ecto-free, so the two lists are kept honest
      # by this assertion rather than by a call into the schema.
      assert Enum.map(BehaviourTestMatrix.statuses(), &Atom.to_string/1) ==
               BehaviourTestRow.statuses()
    end
  end

  describe "check/2 — pass-through" do
    test "an absent matrix adds nothing" do
      assert BehaviourTestMatrix.check([], %{}) == []
    end

    test "an explicit nil matrix adds nothing" do
      assert BehaviourTestMatrix.check([], %{"behaviour_test_matrix" => nil}) == []
    end

    test "a partial verdict — no status, no rows — adds nothing" do
      assert BehaviourTestMatrix.check([], %{"behaviour_test_matrix" => %{}}) == []
    end

    test "an explicit nil status and nil rows add nothing" do
      verdict = %{"status" => nil, "rows" => nil}
      assert BehaviourTestMatrix.check([], %{"behaviour_test_matrix" => verdict}) == []
    end

    test "a non-map matrix is rejected" do
      assert BehaviourTestMatrix.check([], %{"behaviour_test_matrix" => "no"}) ==
               [{:behaviour_test_matrix_entry, "behaviour_test_matrix must be a map"}]
    end
  end

  describe "check/2 — accumulator contract" do
    test "pre-existing errors pass through untouched" do
      seeded = [{:earlier, "first"}]
      assert BehaviourTestMatrix.check(seeded, %{}) == seeded
    end

    test "new failures are PREPENDED and the list is left unreversed" do
      # The caller reverses once at the end; returning a reversed list here
      # would silently reorder the whole report.
      verdict = %{"rows" => "not a list"}

      assert BehaviourTestMatrix.check(
               [{:earlier, "first"}],
               %{"behaviour_test_matrix" => verdict}
             ) ==
               [
                 {:behaviour_test_matrix_rows, "behaviour_test_matrix.rows must be a list"},
                 {:earlier, "first"}
               ]
    end
  end

  describe "check/2 — supplied shapes" do
    defp matrix(verdict), do: %{"behaviour_test_matrix" => verdict}

    test "a recognized status is accepted" do
      assert BehaviourTestMatrix.check([], matrix(%{"status" => "passed"})) == []
    end

    test "an unrecognized status reports the section allow-list" do
      assert BehaviourTestMatrix.check([], matrix(%{"status" => "maybe"})) ==
               [
                 {:behaviour_test_matrix_status,
                  "behaviour_test_matrix status must be one of: passed, failed, not_assessed"}
               ]
    end

    test "a complete row is accepted" do
      row = %{"category" => "Happy path", "behaviour" => "does the thing", "status" => "passing"}
      assert BehaviourTestMatrix.check([], matrix(%{"rows" => [row]})) == []
    end

    test "a row missing a required string is rejected by index" do
      row = %{"behaviour" => "does the thing", "status" => "passing"}

      assert BehaviourTestMatrix.check([], matrix(%{"rows" => [row]})) ==
               [
                 {:behaviour_test_row_field,
                  "behaviour_test_matrix.rows[0] must have a non-empty string \"category\""}
               ]
    end

    test "a supplied optional key must still be a string" do
      row = %{
        "category" => "Happy path",
        "behaviour" => "does the thing",
        "status" => "passing",
        "test_name" => 7
      }

      assert BehaviourTestMatrix.check([], matrix(%{"rows" => [row]})) ==
               [
                 {:behaviour_test_row_field,
                  "behaviour_test_matrix.rows[0] \"test_name\" must be a string when supplied"}
               ]
    end

    test "a waived row needs no test_name" do
      row = %{
        "category" => "Boundary",
        "behaviour" => "n/a here",
        "status" => "not_applicable"
      }

      assert BehaviourTestMatrix.check([], matrix(%{"rows" => [row]})) == []
    end

    test "a non-map row is rejected by index" do
      assert BehaviourTestMatrix.check([], matrix(%{"rows" => ["nope"]})) ==
               [{:behaviour_test_row_entry, "behaviour_test_matrix.rows[0] must be a map"}]
    end
  end
end
