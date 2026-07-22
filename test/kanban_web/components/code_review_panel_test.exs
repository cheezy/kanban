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

    test "renders a not_applicable check as a neutral N/A pill (W1058)" do
      task = %{
        id: 11,
        identifier: "W11",
        reviewer_result: %{
          "project_checks" => [
            %{
              "check" => "All user-facing strings are wrapped in gettext.",
              "status" => "not_applicable",
              "evidence" => "No user-facing strings in this diff."
            }
          ]
        }
      }

      html = render_with(task)

      assert html =~ ~s(data-review-code-review-status="not_applicable")
      # The pill label is the translated "N/A" (note the escaped slash).
      assert html =~ ~r/N\/A\s*<\/span>/
      assert html =~ "No user-facing strings in this diff."
      assert length(Regex.scan(~r/data-review-code-review-row/, html)) == 1
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

  defp render_breakdown(task) do
    assigns = %{task: task}

    rendered_to_string(~H"""
    <CodeReviewPanel.security_considerations_breakdown task={@task} />
    """)
  end

  describe "security_considerations_breakdown/1 (W1867)" do
    test "renders one row per consideration with the right pill and text" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "status" => "failed",
            "considerations" => [
              %{"consideration" => "Untrusted status never atom-ized", "status" => "mitigated"},
              %{
                "consideration" => "Diff text is unbounded",
                "status" => "partial",
                "evidence" => "capped at 500 lines"
              },
              %{"consideration" => "Input not sanitized", "status" => "unmitigated"}
            ]
          }
        }
      }

      html = render_breakdown(task)

      assert html =~ "data-review-security-considerations-breakdown"
      assert length(Regex.scan(~r/data-review-security-consideration-row/, html)) == 3
      assert html =~ ~s(data-review-security-consideration-status="mitigated")
      assert html =~ ~s(data-review-security-consideration-status="partial")
      assert html =~ ~s(data-review-security-consideration-status="unmitigated")

      assert html =~ "Untrusted status never atom-ized"
      assert html =~ "Diff text is unbounded"
      assert html =~ "Input not sanitized"

      assert html =~ ~r/Mitigated\s*<\/span>/
      assert html =~ ~r/Partial\s*<\/span>/
      assert html =~ ~r/Unmitigated\s*<\/span>/

      # Evidence renders as the secondary detail line.
      assert html =~ "data-review-security-consideration-detail"
      assert html =~ "capped at 500 lines"
    end

    test "renders a consideration without evidence/note without the detail line" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [%{"consideration" => "No detail here", "status" => "mitigated"}]
          }
        }
      }

      html = render_breakdown(task)

      assert html =~ "No detail here"
      refute html =~ "data-review-security-consideration-detail"
    end

    test "renders nothing when the breakdown is absent (graceful degradation)" do
      task = %{reviewer_result: %{"security_considerations" => %{"status" => "passed"}}}

      html = render_breakdown(task)

      refute html =~ "data-review-security-considerations-breakdown"
      refute html =~ "data-review-security-consideration-row"
    end

    test "renders nothing when reviewer_result is nil (legacy completion)" do
      html = render_breakdown(%{reviewer_result: nil})

      refute html =~ "data-review-security-considerations-breakdown"
    end

    test "renders an unknown status verbatim with a neutral pill" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [%{"consideration" => "Weird", "status" => "deferred"}]
          }
        }
      }

      html = render_breakdown(task)

      assert html =~ ~s(data-review-security-consideration-status="deferred")
      assert html =~ ~r/deferred\s*<\/span>/
    end

    test "escapes agent-supplied consideration and detail strings (no XSS)" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [
              %{
                "consideration" => "<script>alert('xss')</script>",
                "status" => "unmitigated",
                "evidence" => "<img src=x onerror=alert(1)>"
              }
            ]
          }
        }
      }

      html = render_breakdown(task)

      refute html =~ "<script>alert('xss')</script>"
      refute html =~ "<img src=x onerror=alert(1)>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    end

    test "uses only theme-aware tokens (no hardcoded grays/whites)" do
      task = %{
        reviewer_result: %{
          "security_considerations" => %{
            "considerations" => [
              %{"consideration" => "a", "status" => "mitigated"},
              %{"consideration" => "b", "status" => "partial"},
              %{"consideration" => "c", "status" => "unmitigated"}
            ]
          }
        }
      }

      html = render_breakdown(task)

      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ ~r/border-gray-\d+/
    end
  end
end
