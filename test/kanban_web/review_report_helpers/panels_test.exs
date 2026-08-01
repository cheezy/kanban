defmodule KanbanWeb.ReviewReportHelpers.PanelsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ReviewReportHelpers.Explorer
  alias KanbanWeb.ReviewReportHelpers.Panels

  describe "review panel visibility predicates (W1085)" do
    test "visible with a non-empty reviewer_result map" do
      task = %{reviewer_result: %{"dispatched" => true}, review_report: nil}

      assert Panels.review_panel_visible?(task)
      assert Panels.has_reviewer_result?(task)
      refute Panels.has_review_report?(task)
    end

    test "visible with a non-empty review_report string" do
      task = %{reviewer_result: nil, review_report: "## Approved"}

      assert Panels.review_panel_visible?(task)
      refute Panels.has_reviewer_result?(task)
      assert Panels.has_review_report?(task)
    end

    test "visible with both present" do
      task = %{reviewer_result: %{"status" => "approved"}, review_report: "report"}

      assert Panels.review_panel_visible?(task)
    end

    test "hidden with neither present" do
      refute Panels.review_panel_visible?(%{
               reviewer_result: nil,
               review_report: nil
             })

      refute Panels.review_panel_visible?(%{})
    end

    test "an empty-map reviewer_result does not make the panel visible" do
      task = %{reviewer_result: %{}, review_report: nil}

      refute Panels.has_reviewer_result?(task)
      refute Panels.review_panel_visible?(task)
    end

    test "an empty review_report string does not make the panel visible" do
      refute Panels.has_review_report?(%{review_report: ""})
    end

    test "a whitespace-only review_report counts as content, matching the original predicate" do
      task = %{review_report: "   "}

      assert Panels.has_review_report?(task)
      assert Panels.review_panel_visible?(task)
    end
  end

  describe "review_or_done?/1 (W1962)" do
    test "true when review_status is set and status is still :in_progress" do
      assert Panels.review_or_done?(%{
               review_status: :changes_requested,
               status: :in_progress
             })
    end

    test "true for every review_status value, whatever the status" do
      for review_status <- [:pending, :approved, :changes_requested, :rejected] do
        assert Panels.review_or_done?(%{
                 review_status: review_status,
                 status: :open
               })
      end
    end

    test "true when status is :completed and review_status is nil" do
      assert Panels.review_or_done?(%{review_status: nil, status: :completed})
    end

    test "false for an open or in-progress task with review_status nil" do
      for status <- [:open, :in_progress, :blocked] do
        refute Panels.review_or_done?(%{review_status: nil, status: status})
      end
    end

    test "accepts a string-keyed task map" do
      assert Panels.review_or_done?(%{
               "review_status" => "approved",
               "status" => "in_progress"
             })

      assert Panels.review_or_done?(%{
               "review_status" => nil,
               "status" => "completed"
             })

      refute Panels.review_or_done?(%{
               "review_status" => nil,
               "status" => "in_progress"
             })
    end

    test "is not gated on needs_review or column name" do
      refute Panels.review_or_done?(%{
               review_status: nil,
               status: :in_progress,
               needs_review: true,
               column_name: "Review"
             })
    end

    test "false for a map missing both keys, and for a non-map" do
      refute Panels.review_or_done?(%{})
      refute Panels.review_or_done?(nil)
      refute Panels.review_or_done?("completed")
    end
  end

  describe "completion_panel_visible?/1 (W1962)" do
    test "true for a review-or-done task carrying only completion_notes" do
      assert Panels.completion_panel_visible?(%{
               review_status: nil,
               status: :completed,
               completion_notes: "Did the thing."
             })
    end

    test "true when any single field from the preserved guard set is present" do
      for field <- [:completed_at, :completed_by, :completed_by_agent, :completion_summary] do
        task = Map.merge(%{review_status: nil, status: :completed}, %{field => "value"})

        assert Panels.completion_panel_visible?(task),
               "expected #{field} alone to make the completion panel visible"
      end
    end

    test "false for a review-or-done task with no completion fields at all" do
      refute Panels.completion_panel_visible?(%{
               review_status: :approved,
               status: :completed
             })

      refute Panels.completion_panel_visible?(%{
               review_status: nil,
               status: :completed,
               completed_at: nil,
               completed_by: nil,
               completed_by_agent: nil,
               completion_summary: nil,
               completion_notes: nil
             })
    end

    test "false for an open task even when it carries completion fields" do
      refute Panels.completion_panel_visible?(%{
               review_status: nil,
               status: :open,
               completion_summary: "Somehow set"
             })
    end

    test "an unloaded completed_by association reads as absent, not as content" do
      not_loaded = %Ecto.Association.NotLoaded{
        __field__: :completed_by,
        __owner__: Kanban.Tasks.Task,
        __cardinality__: :one
      }

      refute Panels.completion_panel_visible?(%{
               review_status: nil,
               status: :completed,
               completed_by: not_loaded
             })
    end

    test "accepts a string-keyed task map" do
      assert Panels.completion_panel_visible?(%{
               "review_status" => nil,
               "status" => "completed",
               "completion_notes" => "Did the thing."
             })

      refute Panels.completion_panel_visible?(%{
               "review_status" => nil,
               "status" => "in_progress",
               "completion_notes" => "Did the thing."
             })
    end
  end

  describe "changed_files_panel_visible?/1 (W1962)" do
    test "true for a completed task with a non-empty changed_files list" do
      assert Panels.changed_files_panel_visible?(%{
               review_status: nil,
               status: :completed,
               changed_files: [%{"path" => "lib/foo.ex"}]
             })
    end

    test "false when changed_files is the schema default empty list, or nil" do
      for changed_files <- [[], nil] do
        refute Panels.changed_files_panel_visible?(%{
                 review_status: :approved,
                 status: :completed,
                 changed_files: changed_files
               })
      end
    end

    test "false when changed_files is missing entirely or not a list" do
      refute Panels.changed_files_panel_visible?(%{
               review_status: :approved,
               status: :completed
             })

      refute Panels.changed_files_panel_visible?(%{
               review_status: :approved,
               status: :completed,
               changed_files: "lib/foo.ex"
             })
    end

    test "false for an open task even with a non-empty changed_files list" do
      refute Panels.changed_files_panel_visible?(%{
               review_status: nil,
               status: :open,
               changed_files: [%{"path" => "lib/foo.ex"}]
             })
    end

    test "accepts a string-keyed task map" do
      assert Panels.changed_files_panel_visible?(%{
               "review_status" => nil,
               "status" => "completed",
               "changed_files" => [%{"path" => "lib/foo.ex"}]
             })

      refute Panels.changed_files_panel_visible?(%{
               "review_status" => nil,
               "status" => "in_progress",
               "changed_files" => [%{"path" => "lib/foo.ex"}]
             })
    end
  end

  describe "the review-or-done gate has exactly one definition (W1962)" do
    # Every panel predicate must agree with review_or_done?/1 on the gate half,
    # for every status/review_status combination — which is only guaranteed
    # while they all delegate to it rather than restating the boolean.
    test "all three panel predicates agree with review_or_done?/1 on the gate" do
      for review_status <- [nil, :pending, :approved, :changes_requested, :rejected],
          status <- [:open, :in_progress, :blocked, :completed] do
        task = %{
          review_status: review_status,
          status: status,
          completion_notes: "Did the thing.",
          changed_files: [%{"path" => "lib/foo.ex"}],
          explorer_result: %{"dispatched" => true}
        }

        gate = Panels.review_or_done?(task)

        assert Panels.completion_panel_visible?(task) == gate
        assert Panels.changed_files_panel_visible?(task) == gate
        assert Explorer.explorer_panel_visible?(task) == gate
      end
    end
  end
end
