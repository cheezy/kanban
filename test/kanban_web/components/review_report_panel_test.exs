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

  # Attaches a telemetry handler that only forwards events for the given
  # task's id. Telemetry handlers are global across the BEAM, so when this
  # module runs with `async: true`, a plain forward-everything handler would
  # also receive events from concurrent renders in other test modules and
  # cause `refute_received` to flap (see the structured_used flake from a
  # parallel ReviewLive test rendering a structured reviewer_result). The
  # per-task filter localizes each test to its own fixture id.
  defp attach_telemetry(event, task) do
    test_pid = self()
    task_id = Map.get(task, :id) || Map.get(task, "id")
    handler_id = "rrp-test-#{event |> Enum.join("-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        if metadata[:task_id] == task_id do
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end
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

    test "no longer renders the status banner or reviewer summary — those are owned by the parent LiveView",
         %{task: task} do
      # The status pill lives next to `summary_text` in `ReviewLive` and
      # the reviewer summary is not needed once the panel is dedicated to
      # the Issues section.
      html = render_with(task)
      refute html =~ "data-review-report-status"
      refute html =~ "Reviewed all the things"
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

    test "does not render an internal acceptance grid — that data is the AcceptanceChecklist's job",
         %{task: task} do
      # The panel used to render its own acceptance criteria grid, but it
      # duplicated the `AcceptanceChecklist` rendered separately by the
      # parent LiveView. The grid was removed to avoid the repetition.
      html = render_with(task)
      refute html =~ "data-review-report-acceptance"
      refute html =~ "data-review-report-acceptance-status"
      refute html =~ "data-review-report-acceptance-row"
    end

    test "no longer renders the section verdict tiles — the parent strip surfaces those",
         %{task: task} do
      html = render_with(task)
      refute html =~ "data-review-report-verdict"
      refute html =~ "data-review-report-verdicts"
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
      attach_telemetry(event, task)

      _ = render_with(task)

      assert_receive {:telemetry_event, ^event, %{count: 1}, %{task_id: 1, identifier: "W42"}}
    end

    test "renders 'No issues' placeholder when issues list is empty", %{task: task} do
      task = put_in(task.reviewer_result["issues"], [])
      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="structured")
      assert html =~ "data-review-report-issues-empty"
      assert html =~ "No issues"
      refute html =~ ~s(data-review-report-issues=")
    end
  end

  describe "project_checks section" do
    # The project_checks rendering moved out of ReviewReportPanel into its
    # own KanbanWeb.CodeReviewPanel component (W: code-review-panel) and the
    # /review LiveView renders it in a separate "CODE REVIEW" section. The
    # tests for the rendering live alongside the new component at
    # test/kanban_web/components/code_review_panel_test.exs. The remaining
    # check in this describe block guards the issues-list category mapping
    # for the legacy `category: "project_check"` shape, which has nothing
    # to do with the project_checks array itself.

    test "renders project_check category in the issues list with localized label" do
      task = %{
        id: 876_004,
        identifier: "W876d",
        reviewer_result: %{
          "schema_version" => "1.1",
          "issues" => [
            %{
              "severity" => "important",
              "category" => "project_check",
              "description" => "Missing @doc"
            }
          ]
        }
      }

      html = render_with(task)

      assert html =~ "data-review-report-issue"
      assert html =~ "Project check:"
      assert html =~ "Missing @doc"
    end

    test "uses theme-aware tokens only — no hardcoded grays" do
      task = %{
        id: 876_005,
        identifier: "W876e",
        reviewer_result: %{
          "schema_version" => "1.1",
          "issues" => [],
          "project_checks" => [
            %{
              "check" => "Test check",
              "source" => "CODE-REVIEW.md",
              "status" => "met",
              "evidence" => "evidence"
            }
          ]
        }
      }

      html = render_with(task)

      assert html =~ "text-base-content"
      assert html =~ "border-base-300"
      refute html =~ "text-gray-900"
      refute html =~ "text-gray-600"
      refute html =~ "bg-white"
      refute html =~ "bg-gray-50"
      refute html =~ "border-gray-200"
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

    test "no longer renders fallback verdict tiles — those moved to the parent strip",
         %{task: task} do
      html = render_with(task)
      refute html =~ "data-review-report-fallback-verdicts"
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
      attach_telemetry(event, task)

      _ = render_with(task)

      assert_receive {:telemetry_event, ^event, %{count: 1}, %{task_id: 7, identifier: "W99"}}
    end

    test "does not emit the structured_used event on the fallback branch", %{task: task} do
      event = [:kanban, :review, :structured_used]
      attach_telemetry(event, task)

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
      attach_telemetry(fallback, task)
      attach_telemetry(structured, task)

      _ = render_with(task)

      refute_received {:telemetry_event, ^fallback, _, _}
      refute_received {:telemetry_event, ^structured, _, _}
    end
  end

  describe "skip-form / summary-only reviewer_result" do
    test "skip-form (dispatched:false) renders the structured shell without a misleading 'No issues'" do
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

      # A skip-form keeps the structured branch, but with no issues[] list it
      # renders an empty shell — never the misleading "No issues" placeholder,
      # and never the reviewer summary (owned by the parent LiveView) (D59).
      assert html =~ ~s(data-review-report-panel="structured")
      refute html =~ "data-review-report-issues-empty"
      refute html =~ "No issues"
      refute html =~ "Self-reviewed the diff"
    end

    test "thin dispatched result with only a summary is not structured (no report to suppress)" do
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

      # A thin reviewer_result (no status/issues/acceptance/section) no longer
      # wins the structured branch; with no review_report it renders nothing
      # rather than a misleading "No issues" shell (D59).
      refute html =~ "data-review-report-panel"
      refute html =~ "No issues"
      assert String.trim(html) == ""
    end

    test "thin dispatched result WITH a review_report falls through to the fallback markdown (D59)" do
      task = %{
        id: 7,
        identifier: "W7",
        reviewer_result: %{
          "dispatched" => true,
          "issues_found" => 2,
          "summary" => "Two issues noted."
        },
        review_report: "### Review\n\nFound two issues that need attention."
      }

      html = render_with(task)

      # The thin reviewer_result must NOT win the structured branch and
      # suppress the report — it falls through to the markdown, and never
      # shows "No issues".
      assert html =~ ~s(data-review-report-panel="fallback")
      refute html =~ ~s(data-review-report-panel="structured")
      refute html =~ "No issues"
      assert html =~ "Found two issues that need attention."
    end

    test "reviewer_result carrying only a security_considerations verdict wins the structured branch" do
      task = %{
        id: 8,
        identifier: "W8",
        reviewer_result: %{
          "dispatched" => true,
          "security_considerations" => %{"status" => "passed"}
        },
        review_report: nil
      }

      html = render_with(task)

      # section_verdict?/1 now recognizes "security_considerations", so a
      # result carrying only that verdict still wins the structured branch
      # rather than rendering an empty shell.
      assert html =~ ~s(data-review-report-panel="structured")
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
      attach_telemetry(event, task)

      html = render_with(task)

      assert html =~ ~s(data-review-report-panel="structured")
      refute html =~ ~s(data-review-report-panel="fallback")
      assert_receive {:telemetry_event, ^event, _, _}
    end
  end

  describe "string-keyed task" do
    test "structured branch reads reviewer_result through string keys" do
      task = %{
        "id" => 11,
        "identifier" => "W11",
        "reviewer_result" => %{
          "status" => "approved",
          "summary" => "String-keyed task"
        }
      }

      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="structured")
      # String-keyed reviewer summaries are no longer rendered in the panel.
      refute html =~ "String-keyed task"
    end

    test "fallback branch reads review_report through string keys" do
      task = %{
        "id" => 12,
        "identifier" => "W12",
        "reviewer_result" => nil,
        "review_report" => "### Patterns followed\n\nUsed standard."
      }

      html = render_with(task)
      assert html =~ ~s(data-review-report-panel="fallback")
      # The fallback now renders the markdown body via Earmark; the
      # "Patterns followed" heading is preserved in the rendered HTML.
      assert html =~ "Patterns followed"
    end
  end

  describe "structured branch — exhaustive label / class coverage" do
    test "renders the 'important' severity group, label, and tone" do
      task = %{
        id: 20,
        identifier: "W20",
        reviewer_result: %{
          "status" => "changes_requested",
          "summary" => "Has important issues",
          "issues" => [
            %{
              "severity" => "important",
              "category" => "acceptance_criteria",
              "description" => "Missing edge case"
            },
            %{
              "severity" => "wat?",
              "category" => "pattern",
              "description" => "Unknown severity buckets to minor"
            }
          ],
          "acceptance_criteria" => [
            %{"criterion" => "Strange item", "status" => "unknown"}
          ],
          "testing_strategy" => "not a map",
          "patterns" => %{"status" => "ambiguous", "notes" => "n/a"},
          "pitfalls" => %{"status" => "rejected"}
        }
      }

      html = render_with(task)

      assert html =~ ~s(data-review-report-issue-group="important")
      assert html =~ ~s(data-review-report-issue-group="minor")
      assert html =~ ~r/important/i
      assert html =~ "text-warning"

      # Category labels still render inside the per-issue line.
      assert html =~ "Acceptance:"
      assert html =~ "Patterns:"

      # The internal acceptance grid, status banner, and section verdict
      # tiles were all moved out of the panel.
      refute html =~ ~s(data-review-report-acceptance-status)
      refute html =~ ~s(data-review-report-acceptance-row)
      refute html =~ "data-review-report-status"
      refute html =~ "data-review-report-verdicts"
      refute html =~ ~s(data-review-report-verdict="testing_strategy")
    end

    test "renders 'rejected' status and the 'testing' / 'code_quality' category labels" do
      task = %{
        id: 21,
        identifier: "W21",
        reviewer_result: %{
          "status" => "rejected",
          "summary" => "Blocked",
          "issues" => [
            %{
              "severity" => "minor",
              "category" => "testing",
              "description" => "Missing unit test"
            },
            %{
              "severity" => "minor",
              "category" => "code_quality",
              "description" => "Long function"
            },
            %{
              "severity" => "minor",
              "category" => "something_else",
              "description" => "Falls back to literal binary"
            },
            %{
              "severity" => "minor",
              "description" => "No category at all"
            }
          ]
        }
      }

      html = render_with(task)

      # The status pill (and its `bg-error` / "rejected" label) was moved
      # out of the panel — only the issue list remains.
      assert html =~ ~r/testing:/i
      assert html =~ ~r/code quality:/i
      assert html =~ "something_else:"
      assert html =~ "No category at all"
    end

    test "arbitrary binary statuses no longer surface inside the panel" do
      # The panel used to render the verbatim status string; with the
      # status pill moved up to the LiveView, an arbitrary "in_review"
      # value should NOT leak into the panel HTML at all.
      task = %{
        id: 22,
        identifier: "W22",
        reviewer_result: %{
          "status" => "in_review",
          "summary" => "Custom status"
        }
      }

      html = render_with(task)
      refute html =~ "in_review"
      refute html =~ "Custom status"
    end
  end
end
