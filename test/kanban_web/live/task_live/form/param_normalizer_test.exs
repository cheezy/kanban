defmodule KanbanWeb.TaskLive.Form.ParamNormalizerTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.ParamNormalizer

  describe "keep_stored_map_keys/2" do
    test "keeps testing_strategy keys the form has no inputs for" do
      task = %Task{
        testing_strategy: %{
          "unit_tests" => ["old"],
          "edge_cases" => ["Board with zero tasks"],
          "coverage_target" => "100%"
        }
      }

      params = %{"testing_strategy" => %{"unit_tests" => ["new"], "manual_tests" => []}}

      assert %{"testing_strategy" => merged} = ParamNormalizer.keep_stored_map_keys(params, task)

      assert merged == %{
               "unit_tests" => ["new"],
               "manual_tests" => [],
               "edge_cases" => ["Board with zero tasks"],
               "coverage_target" => "100%"
             }
    end

    test "keeps integration_points keys the form has no inputs for" do
      task = %Task{integration_points: %{"telemetry_events" => ["a"], "notes" => "keep"}}
      params = %{"integration_points" => %{"telemetry_events" => ["b"]}}

      assert %{"integration_points" => %{"telemetry_events" => ["b"], "notes" => "keep"}} =
               ParamNormalizer.keep_stored_map_keys(params, task)
    end

    test "leaves params alone when the field was not submitted or nothing is stored" do
      task = %Task{testing_strategy: %{"edge_cases" => ["x"]}, integration_points: nil}
      params = %{"title" => "T", "integration_points" => %{"external_apis" => []}}

      assert ParamNormalizer.keep_stored_map_keys(params, task) == params
    end
  end
end
