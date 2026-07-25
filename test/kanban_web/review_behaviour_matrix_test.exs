defmodule KanbanWeb.ReviewBehaviourMatrixTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewBehaviourMatrix

  describe "rows/1 (W1921)" do
    test "returns one normalized row per well-formed entry" do
      task =
        task_with([
          %{
            "category" => "Happy path",
            "behaviour" => "renders one row per matrix row",
            "test_name" => "renders one row per matrix row",
            "type" => "unit",
            "status" => "passing"
          },
          %{
            "category" => "Null / empty",
            "behaviour" => "renders nothing when the verdict is absent",
            "test_name" => "renders nothing when the matrix verdict is absent",
            "type" => "unit / manual",
            "status" => "planned"
          }
        ])

      assert ReviewBehaviourMatrix.rows(task) == [
               %{
                 category: "Happy path",
                 behaviour: "renders one row per matrix row",
                 test_name: "renders one row per matrix row",
                 type: "unit",
                 status: "passing"
               },
               %{
                 category: "Null / empty",
                 behaviour: "renders nothing when the verdict is absent",
                 test_name: "renders nothing when the matrix verdict is absent",
                 type: "unit / manual",
                 status: "planned"
               }
             ]
    end

    test "accepts a string-keyed reviewer_result" do
      task = %{
        "reviewer_result" => %{
          "behaviour_test_matrix" => %{"rows" => [valid_row()]}
        }
      }

      assert [%{category: "Boundary", behaviour: "keeps the row"}] =
               ReviewBehaviourMatrix.rows(task)
    end

    test "normalizes a single row" do
      task = task_with([valid_row()])

      assert length(ReviewBehaviourMatrix.rows(task)) == 1
    end

    test "drops rows whose category or behaviour is missing or blank" do
      task =
        task_with([
          %{"behaviour" => "no category"},
          %{"category" => "Boundary"},
          %{"category" => "   ", "behaviour" => "blank category"},
          %{"category" => "Boundary", "behaviour" => "   "},
          %{"category" => 42, "behaviour" => "non-string category"},
          valid_row()
        ])

      assert [%{behaviour: "keeps the row"}] = ReviewBehaviourMatrix.rows(task)
    end

    test "drops entries that are not maps" do
      task = task_with(["not a map", 42, nil, ["nested"], valid_row()])

      assert [%{behaviour: "keeps the row"}] = ReviewBehaviourMatrix.rows(task)
    end

    test "returns nil test_name and type when the reviewer omitted them" do
      task = task_with([%{"category" => "Concurrency", "behaviour" => "waived row"}])

      assert [row] = ReviewBehaviourMatrix.rows(task)
      assert row.test_name == nil
      assert row.type == nil
      assert row.status == nil
    end

    test "keeps a row whose optional test_name and type are not strings, coercing them to nil" do
      task =
        task_with([
          %{
            "category" => "Boundary",
            "behaviour" => "keeps the row",
            "test_name" => 42,
            "type" => ["unit"],
            "status" => "passing"
          }
        ])

      assert [row] = ReviewBehaviourMatrix.rows(task)
      assert row.behaviour == "keeps the row"
      assert row.test_name == nil
      assert row.type == nil
      assert row.status == "passing"
    end

    test "passes an unknown status through untouched" do
      task = task_with([Map.put(valid_row(), "status", "bogus")])

      assert [%{status: "bogus"}] = ReviewBehaviourMatrix.rows(task)
    end

    test "trims surrounding whitespace on every field" do
      task =
        task_with([
          %{
            "category" => "  Boundary  ",
            "behaviour" => "  keeps the row  ",
            "test_name" => "  a test  ",
            "type" => "  unit  ",
            "status" => "  passing  "
          }
        ])

      assert [
               %{
                 category: "Boundary",
                 behaviour: "keeps the row",
                 test_name: "a test",
                 type: "unit",
                 status: "passing"
               }
             ] = ReviewBehaviourMatrix.rows(task)
    end

    test "returns [] when rows is an empty list" do
      task = task_with([])

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when rows is absent" do
      task = %{reviewer_result: %{"behaviour_test_matrix" => %{"status" => "passed"}}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when rows is not a list" do
      task = %{reviewer_result: %{"behaviour_test_matrix" => %{"rows" => "nope"}}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when rows is nil" do
      task = %{reviewer_result: %{"behaviour_test_matrix" => %{"rows" => nil}}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when behaviour_test_matrix is not a map" do
      task = %{reviewer_result: %{"behaviour_test_matrix" => "nope"}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when behaviour_test_matrix is nil" do
      task = %{reviewer_result: %{"behaviour_test_matrix" => nil}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when behaviour_test_matrix is absent" do
      task = %{reviewer_result: %{"security_considerations" => %{"status" => "passed"}}}

      assert ReviewBehaviourMatrix.rows(task) == []
    end

    test "returns [] when reviewer_result is nil" do
      assert ReviewBehaviourMatrix.rows(%{reviewer_result: nil}) == []
    end

    test "returns [] when the task carries no reviewer_result at all" do
      assert ReviewBehaviourMatrix.rows(%{}) == []
    end
  end

  defp valid_row do
    %{
      "category" => "Boundary",
      "behaviour" => "keeps the row",
      "test_name" => "keeps the row test",
      "type" => "unit",
      "status" => "passing"
    }
  end

  defp task_with(rows) do
    %{reviewer_result: %{"behaviour_test_matrix" => %{"status" => "passed", "rows" => rows}}}
  end
end
