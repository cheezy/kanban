defmodule KanbanWeb.TaskLive.Form.ParamNormalizerTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.ParamNormalizer

  describe "preserve_stored_values/2" do
    test "keeps testing_strategy keys the form has no inputs for" do
      task = %Task{
        testing_strategy: %{
          "unit_tests" => ["old"],
          "edge_cases" => ["Board with zero tasks"],
          "coverage_target" => "100%"
        }
      }

      params = %{"testing_strategy" => %{"unit_tests" => ["new"], "manual_tests" => []}}

      assert %{"testing_strategy" => merged} =
               ParamNormalizer.preserve_stored_values(params, task)

      assert merged == %{
               "unit_tests" => ["new"],
               "edge_cases" => ["Board with zero tasks"],
               "coverage_target" => "100%"
             }
    end

    test "keeps integration_points keys the form has no inputs for" do
      task = %Task{integration_points: %{"telemetry_events" => ["a"], "notes" => "keep"}}
      params = %{"integration_points" => %{"telemetry_events" => ["b"]}}

      assert %{"integration_points" => %{"telemetry_events" => ["b"], "notes" => "keep"}} =
               ParamNormalizer.preserve_stored_values(params, task)
    end

    test "does not add empty lists for keys the stored map never had" do
      task = %Task{integration_points: %{"modules" => ["A"], "telemetry_events" => ["t"]}}

      params = %{
        "integration_points" => %{
          "telemetry_events" => [],
          "external_apis" => [],
          "pubsub_broadcasts" => ["p"]
        }
      }

      assert %{"integration_points" => merged} =
               ParamNormalizer.preserve_stored_values(params, task)

      assert merged == %{
               "modules" => ["A"],
               "telemetry_events" => [],
               "pubsub_broadcasts" => ["p"]
             }
    end

    test "leaves params alone when the field was not submitted" do
      task = %Task{testing_strategy: %{"edge_cases" => ["x"]}}
      params = %{"title" => "T"}

      assert ParamNormalizer.preserve_stored_values(params, task) == params
    end

    test "keeps a nil map nil when the form submitted only empty lists" do
      task = %Task{testing_strategy: nil, integration_points: nil}

      params = %{
        "title" => "T",
        "integration_points" => %{"external_apis" => [], "telemetry_events" => []},
        "testing_strategy" => %{"unit_tests" => ["New test"], "manual_tests" => []}
      }

      assert ParamNormalizer.preserve_stored_values(params, task) == %{
               "title" => "T",
               "testing_strategy" => %{"unit_tests" => ["New test"]}
             }
    end

    test "drops an empty list for a list field the task never had" do
      task = %Task{pitfalls: nil, out_of_scope: ["Stored"], technology_requirements: nil}

      params = %{
        "pitfalls" => [],
        "out_of_scope" => [],
        "technology_requirements" => ["Ecto"]
      }

      assert ParamNormalizer.preserve_stored_values(params, task) == %{
               "out_of_scope" => [],
               "technology_requirements" => ["Ecto"]
             }
    end
  end
end
