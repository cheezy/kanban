defmodule KanbanWeb.CodeReviewPanelTest do
  @moduledoc """
  Unit tests for the standalone CODE REVIEW panel that lives next to
  the issues panel on the review queue detail view.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.CodeReviewPanel

  defp render_with(task) do
    assigns = %{task: task}

    rendered_to_string(~H"""
    <CodeReviewPanel.code_review_panel task={@task} />
    """)
  end

  describe "code_review_panel/1" do
    test "renders one row per project_check entry with met / not_met pills + evidence" do
      task = %{
        id: 1,
        identifier: "W1",
        reviewer_result: %{
          "project_checks" => [
            %{
              "check" => "CRITICAL: No Ecto query appears directly in a LiveView file.",
              "status" => "met",
              "evidence" => "Verified — show.ex calls Kanban.Tasks.reorder/3."
            },
            %{
              "check" => "Forms in LiveView use the <.input> component.",
              "status" => "not_met",
              "evidence" => "lib/kanban_web/live/board_live/show.ex:412 uses raw <input>."
            }
          ]
        }
      }

      html = render_with(task)

      assert html =~ "data-review-code-review"
      assert html =~ ~s(data-review-code-review-status="met")
      assert html =~ ~s(data-review-code-review-status="not_met")

      # Both check texts present.
      assert html =~ "No Ecto query appears directly in a LiveView file."
      assert html =~ "Forms in LiveView use the &lt;.input&gt; component."

      # Both evidence strings present.
      assert html =~ "Verified — show.ex calls Kanban.Tasks.reorder/3."
      assert html =~ "lib/kanban_web/live/board_live/show.ex:412 uses raw"

      # Both pill labels present (HTML splits across whitespace between
      # the opening tag and the label text, so match more loosely).
      assert html =~ ~r/Met\s*<\/span>/
      assert html =~ ~r/Not met\s*<\/span>/

      # One row per check.
      assert length(Regex.scan(~r/data-review-code-review-row/, html)) == 2
    end

    test "renders nothing when project_checks is absent (legacy reviewer_result shape)" do
      task = %{id: 2, identifier: "W2", reviewer_result: %{"issues" => []}}

      html = render_with(task)

      refute html =~ "data-review-code-review-row"
      # The outer <ul> is :if-gated so it shouldn't render either.
      refute html =~ "data-review-code-review"
    end

    test "renders nothing when project_checks is an empty list" do
      task = %{id: 3, identifier: "W3", reviewer_result: %{"project_checks" => []}}

      html = render_with(task)

      refute html =~ "data-review-code-review-row"
      refute html =~ "data-review-code-review"
    end

    test "renders nothing when reviewer_result is nil" do
      task = %{id: 4, identifier: "W4", reviewer_result: nil}

      html = render_with(task)

      refute html =~ "data-review-code-review"
    end

    test "renders a check that has no evidence without the secondary line" do
      task = %{
        id: 5,
        identifier: "W5",
        reviewer_result: %{
          "project_checks" => [
            %{"check" => "Reversible migrations.", "status" => "met"}
          ]
        }
      }

      html = render_with(task)

      assert html =~ "Reversible migrations."
      refute html =~ "data-review-code-review-evidence"
    end

    test "renders an unknown status verbatim with a neutral pill" do
      task = %{
        id: 6,
        identifier: "W6",
        reviewer_result: %{
          "project_checks" => [
            %{"check" => "Partial coverage check.", "status" => "partial"}
          ]
        }
      }

      html = render_with(task)

      assert html =~ ~s(data-review-code-review-status="partial")
      assert html =~ ~r/partial\s*<\/span>/
    end

    test "uses only theme-aware tokens (no hardcoded grays/whites)" do
      task = %{
        id: 7,
        identifier: "W7",
        reviewer_result: %{
          "project_checks" => [
            %{"check" => "Theme check.", "status" => "met"}
          ]
        }
      }

      html = render_with(task)

      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ ~r/border-gray-\d+/
    end
  end

  describe "checks_for/1" do
    test "returns the list when present" do
      task = %{
        reviewer_result: %{
          "project_checks" => [
            %{"check" => "X", "status" => "met"}
          ]
        }
      }

      assert [%{"check" => "X"}] = CodeReviewPanel.checks_for(task)
    end

    test "returns [] when reviewer_result has no project_checks key" do
      assert [] = CodeReviewPanel.checks_for(%{reviewer_result: %{"issues" => []}})
    end

    test "returns [] when reviewer_result is nil" do
      assert [] = CodeReviewPanel.checks_for(%{reviewer_result: nil})
    end

    test "returns [] when reviewer_result is a non-map" do
      assert [] = CodeReviewPanel.checks_for(%{reviewer_result: "garbage"})
    end

    test "wraps a non-list project_checks value into a list (defensive)" do
      task = %{reviewer_result: %{"project_checks" => %{"check" => "single", "status" => "met"}}}
      assert [%{"check" => "single"}] = CodeReviewPanel.checks_for(task)
    end
  end
end
