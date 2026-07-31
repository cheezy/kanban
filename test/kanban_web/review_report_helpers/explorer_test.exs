defmodule KanbanWeb.ReviewReportHelpers.ExplorerTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers.Explorer

  describe "has_explorer_result?/1 (W1958)" do
    test "true for a populated explorer_result map" do
      assert Explorer.has_explorer_result?(%{
               explorer_result: %{"dispatched" => true}
             })
    end

    test "false for an empty map, for nil, and for a task map with no explorer_result key" do
      refute Explorer.has_explorer_result?(%{explorer_result: %{}})
      refute Explorer.has_explorer_result?(%{explorer_result: nil})
      refute Explorer.has_explorer_result?(%{})
    end

    test "accepts a string-keyed task map" do
      assert Explorer.has_explorer_result?(%{
               "explorer_result" => %{"dispatched" => true}
             })

      refute Explorer.has_explorer_result?(%{"explorer_result" => %{}})
      refute Explorer.has_explorer_result?(%{"explorer_result" => nil})
    end

    test "false for a non-map explorer_result" do
      refute Explorer.has_explorer_result?(%{explorer_result: "dispatched"})
      refute Explorer.has_explorer_result?(%{explorer_result: []})
    end
  end

  describe "explorer_panel_visible?/1 (W1958)" do
    test "true when explorer_result is populated and review_status is set" do
      assert Explorer.explorer_panel_visible?(%{
               explorer_result: %{"dispatched" => true},
               review_status: :approved,
               status: :in_progress
             })
    end

    test "true when explorer_result is populated and status is :completed" do
      assert Explorer.explorer_panel_visible?(%{
               explorer_result: %{"dispatched" => true},
               review_status: nil,
               status: :completed
             })
    end

    test "false for an open or in-progress task with no review_status" do
      for status <- [:open, :in_progress] do
        refute Explorer.explorer_panel_visible?(%{
                 explorer_result: %{"dispatched" => true},
                 review_status: nil,
                 status: status
               })
      end
    end

    test "false when explorer_result is empty even for a completed task" do
      refute Explorer.explorer_panel_visible?(%{
               explorer_result: %{},
               review_status: :approved,
               status: :completed
             })
    end

    test "false when explorer_result is missing entirely" do
      refute Explorer.explorer_panel_visible?(%{status: :completed})
      refute Explorer.explorer_panel_visible?(%{})
    end

    test "accepts a string-keyed task map" do
      assert Explorer.explorer_panel_visible?(%{
               "explorer_result" => %{"dispatched" => true},
               "review_status" => "approved",
               "status" => "in_progress"
             })

      assert Explorer.explorer_panel_visible?(%{
               "explorer_result" => %{"dispatched" => true},
               "review_status" => nil,
               "status" => "completed"
             })

      refute Explorer.explorer_panel_visible?(%{
               "explorer_result" => %{"dispatched" => true},
               "review_status" => nil,
               "status" => "in_progress"
             })
    end

    test "is not gated on needs_review or column name" do
      task = %{
        explorer_result: %{"dispatched" => true},
        review_status: nil,
        status: :completed,
        needs_review: false
      }

      assert Explorer.explorer_panel_visible?(task)
    end
  end

  describe "skip_reason_label/1 (W1958)" do
    test "returns a non-empty label for each of the five enum values" do
      for reason <- [
            "no_subagent_support",
            "small_task_0_1_key_files",
            "trivial_change_docs_only",
            "self_reported_exploration",
            "self_reported_review"
          ] do
        label = Explorer.skip_reason_label(reason)

        assert is_binary(label)
        assert label != ""
        refute label == reason
      end
    end

    test "each of the five enum values maps to a distinct label" do
      labels =
        Enum.map(
          [
            "no_subagent_support",
            "small_task_0_1_key_files",
            "trivial_change_docs_only",
            "self_reported_exploration",
            "self_reported_review"
          ],
          &Explorer.skip_reason_label/1
        )

      assert length(Enum.uniq(labels)) == 5
    end

    test "returns the raw string for an unrecognized value without raising" do
      assert Explorer.skip_reason_label("some_future_reason") == "some_future_reason"
      assert Explorer.skip_reason_label("") == ""
    end

    test "returns an empty string for a non-binary value without raising" do
      assert Explorer.skip_reason_label(nil) == ""
      assert Explorer.skip_reason_label(:self_reported_review) == ""
      assert Explorer.skip_reason_label(42) == ""
    end

    test "does not convert the incoming value to an atom" do
      before = :erlang.system_info(:atom_count)

      Explorer.skip_reason_label("definitely_not_an_existing_atom_w1958")

      assert :erlang.system_info(:atom_count) == before
    end
  end
end
