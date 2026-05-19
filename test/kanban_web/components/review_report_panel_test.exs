defmodule KanbanWeb.ReviewReportPanelTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewReportPanel

  defp render_with(task) do
    assigns = %{task: task}

    rendered_to_string(~H"""
    <ReviewReportPanel.review_report_panel task={@task} />
    """)
  end

  defp attach_telemetry(event) do
    test_pid = self()
    handler_id = "rrp-test-#{event |> Enum.join("-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  describe "structured branch" do
    setup do
      task = %{
        id: 1,
        identifier: "W42",
        reviewer_result: %{
          "dispatched" => true,
          "schema_version" => "1.0",
          "status" => "approved",
          "summary" => "Reviewed all the things",
          "issues" => [
            %{"severity" => "critical", "category" => "pitfall", "description" => "Big problem"},
            %{"severity" => "minor", "category" => "code_quality", "description" => "Tiny nit"}
          ],
          "acceptance_criteria" => [
            %{"criterion" => "Feature works", "status" => "met"},
            %{"criterion" => "Edge case handled", "status" => "not_met"}
          ],
          "testing_strategy" => %{"status" => "passed", "notes" => "All cases covered"},
          "patterns" => %{"status" => "failed", "notes" => "Inconsistent naming"},
          "pitfalls" => %{"status" => "not_assessed"}
        }
      }

      %{task: task}
    end

    test "renders with the structured branch marker", %{task: task} do
      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="structured")
    end

    test "renders the status banner and summary", %{task: task} do
      html = render_with(task)
      assert html =~ "data-review-report-status"
      assert html =~ "Approved"
      assert html =~ "Reviewed all the things"
    end

    test "renders severity-grouped issue list with critical first", %{task: task} do
      html = render_with(task)
      assert html =~ ~s(data-review-report-issue-group="critical")
      assert html =~ ~s(data-review-report-issue-group="minor")
      assert html =~ "Big problem"
      assert html =~ "Tiny nit"
      assert html =~ "Pitfalls:"

      crit_idx = :binary.match(html, ~s(data-review-report-issue-group="critical")) |> elem(0)
      minor_idx = :binary.match(html, ~s(data-review-report-issue-group="minor")) |> elem(0)
      assert crit_idx < minor_idx
    end

    test "renders the acceptance grid with met / not_met statuses", %{task: task} do
      html = render_with(task)
      assert html =~ "data-review-report-acceptance"
      assert html =~ ~s(data-review-report-acceptance-status="met")
      assert html =~ ~s(data-review-report-acceptance-status="not_met")
      assert html =~ "Feature works"
      assert html =~ "Edge case handled"
    end

    test "renders the three section verdict tiles", %{task: task} do
      html = render_with(task)
      assert html =~ ~s(data-review-report-verdict="testing_strategy")
      assert html =~ ~s(data-review-report-verdict="patterns")
      assert html =~ ~s(data-review-report-verdict="pitfalls")
      assert html =~ ~s(data-review-report-verdict-status="passed")
      assert html =~ ~s(data-review-report-verdict-status="failed")
      assert html =~ ~s(data-review-report-verdict-status="not_assessed")
      assert html =~ "All cases covered"
      assert html =~ "Inconsistent naming"
    end

    test "uses daisyUI theme tokens (no hardcoded gray/white)", %{task: task} do
      html = render_with(task)
      assert html =~ "bg-base-100"
      assert html =~ "text-base-content"
      assert html =~ "border-base-300"
      refute html =~ "bg-white"
      refute html =~ "text-gray-900"
      refute html =~ "border-gray-200"
    end

    test "emits the [:kanban, :review, :structured_used] telemetry event", %{task: task} do
      event = [:kanban, :review, :structured_used]
      attach_telemetry(event)

      _ = render_with(task)

      assert_receive {:telemetry_event, ^event, %{count: 1}, %{task_id: 1, identifier: "W42"}}
    end

    test "renders even when issues list is empty", %{task: task} do
      task = put_in(task.reviewer_result["issues"], [])
      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="structured")
      refute html =~ "data-review-report-issues"
    end
  end

  describe "fallback branch" do
    setup do
      report = """
      ## Approved

      Looks good overall.

      ### Required test cases (all present)

      - Handles login
      - Handles logout
      - Handles refresh

      ### Patterns followed

      Used existing changeset pattern.

      ### Pitfalls

      None violated.
      """

      task = %{
        id: 7,
        identifier: "W99",
        review_report: report,
        reviewer_result: nil
      }

      %{task: task, report: report}
    end

    test "renders with the fallback branch marker", %{task: task} do
      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="fallback")
    end

    test "delegates to ReviewReportHelpers for verdict tile values", %{task: task} do
      html = render_with(task)
      assert html =~ "data-review-report-fallback-verdicts"
      assert html =~ "cases · all present"
      assert html =~ "followed"
      assert html =~ "none violated"
    end

    test "renders the markdown body via Earmark", %{task: task, report: report} do
      html = render_with(task)
      assert html =~ "data-review-report-fallback-body"
      assert html =~ ~r{<h2>\s*Approved\s*</h2>}
      assert html =~ ~r{<h3>\s*Required test cases}
      _ = report
    end

    test "emits the [:kanban, :review, :fallback_used] telemetry event", %{task: task} do
      event = [:kanban, :review, :fallback_used]
      attach_telemetry(event)

      _ = render_with(task)

      assert_receive {:telemetry_event, ^event, %{count: 1}, %{task_id: 7, identifier: "W99"}}
    end

    test "does not emit the structured_used event on the fallback branch", %{task: task} do
      event = [:kanban, :review, :structured_used]
      attach_telemetry(event)

      _ = render_with(task)

      refute_received {:telemetry_event, ^event, _, _}
    end

    test "uses daisyUI theme tokens (no hardcoded gray/white)", %{task: task} do
      html = render_with(task)
      assert html =~ "bg-base-100"
      assert html =~ "text-base-content"
      refute html =~ "bg-white"
      refute html =~ "text-gray-900"
    end
  end

  describe "empty branch" do
    test "renders nothing when neither reviewer_result.issues nor review_report is present" do
      task = %{id: 1, identifier: "W1", reviewer_result: nil, review_report: nil}
      html = render_with(task)

      refute html =~ "data-review-report-panel"
      assert String.trim(html) == ""
    end

    test "renders nothing when reviewer_result is an empty map and review_report is nil" do
      task = %{id: 2, identifier: "W2", reviewer_result: %{}, review_report: nil}

      html = render_with(task)
      refute html =~ "data-review-report-panel"
      assert String.trim(html) == ""
    end

    test "renders nothing when reviewer_result is not a map" do
      task = %{id: 2, identifier: "W2", reviewer_result: "unexpected", review_report: nil}

      html = render_with(task)
      refute html =~ "data-review-report-panel"
      assert String.trim(html) == ""
    end

    test "emits neither telemetry event" do
      task = %{id: 3, identifier: "W3", reviewer_result: nil, review_report: nil}
      fallback = [:kanban, :review, :fallback_used]
      structured = [:kanban, :review, :structured_used]
      attach_telemetry(fallback)
      attach_telemetry(structured)

      _ = render_with(task)

      refute_received {:telemetry_event, ^fallback, _, _}
      refute_received {:telemetry_event, ^structured, _, _}
    end
  end

  describe "skip-form / summary-only reviewer_result" do
    test "renders the structured shell with just the summary when issues is absent" do
      task = %{
        id: 5,
        identifier: "W5",
        reviewer_result: %{
          "dispatched" => false,
          "reason" => "small_task_0_1_key_files",
          "summary" => "Self-reviewed the diff against acceptance criteria; no issues found."
        },
        review_report: nil
      }

      html = render_with(task)

      assert html =~ ~s(data-review-report-panel="structured")
      assert html =~ "Self-reviewed the diff against acceptance criteria"
      refute html =~ "data-review-report-issues"
      refute html =~ "data-review-report-acceptance"
      refute html =~ "data-review-report-verdicts"
    end

    test "renders a dispatched-true reviewer_result with only a summary" do
      task = %{
        id: 6,
        identifier: "W6",
        reviewer_result: %{
          "dispatched" => true,
          "summary" => "Reviewer notes go here."
        },
        review_report: nil
      }

      html = render_with(task)

      assert html =~ ~s(data-review-report-panel="structured")
      assert html =~ "Reviewer notes go here."
    end
  end

  describe "mixed legacy + structured fields" do
    test "structured branch wins when both reviewer_result.issues and review_report are present" do
      task = %{
        id: 4,
        identifier: "W4",
        reviewer_result: %{
          "status" => "approved",
          "summary" => "Structured win",
          "issues" => [],
          "acceptance_criteria" => []
        },
        review_report: "### Required test cases\n\n- A"
      }

      event = [:kanban, :review, :structured_used]
      attach_telemetry(event)

      html = render_with(task)

      assert html =~ ~s(data-review-report-panel="structured")
      refute html =~ ~s(data-review-report-panel="fallback")
      assert_receive {:telemetry_event, ^event, _, _}
    end
  end
end
