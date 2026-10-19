defmodule KanbanWeb.TaskLive.Form.ParamNormalizerLockedTest do
  @moduledoc """
  `ParamNormalizer.normalize_params/3` on a locked board: which dropped paid
  fields it reports as lost changes.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.PlansHelpers

  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.ParamNormalizer

  @task %Task{telemetry_event: "[:stored]", metrics_to_track: nil}

  setup do
    %{board: board_fixture(user_fixture())}
  end

  describe "normalize_params/3 on a free board under enforcement" do
    setup :enforce_plans

    test "drops both fields and reports only the ones that were changes", %{board: board} do
      params = %{
        "title" => "T",
        "telemetry_event" => "[:changed]",
        "metrics_to_track" => "New metric"
      }

      assert {stripped, lost} = ParamNormalizer.normalize_params(params, board, @task)
      assert stripped == %{"title" => "T"}
      assert lost == ["telemetry_event", "metrics_to_track"]
    end

    test "does not report a resubmitted stored value or a blank one", %{board: board} do
      params = %{"telemetry_event" => "[:stored]", "metrics_to_track" => "  "}

      assert {%{}, []} = ParamNormalizer.normalize_params(params, board, @task)
    end

    test "compares against an empty task when none is given", %{board: board} do
      assert {%{}, ["telemetry_event"]} =
               ParamNormalizer.normalize_params(%{"telemetry_event" => "[:new]"}, board)
    end
  end

  describe "normalize_params/3 without enforcement" do
    test "keeps the fields and reports nothing", %{board: board} do
      params = %{"telemetry_event" => "[:changed]"}

      assert {^params, []} = ParamNormalizer.normalize_params(params, board, @task)
    end
  end
end
