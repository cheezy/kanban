defmodule KanbanWeb.ReviewDetailHeaderTest do
  @moduledoc """
  Tests for `KanbanWeb.ReviewDetailHeader.review_detail_header/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewDetailHeader

  defp task(overrides) do
    base = %{
      identifier: "W101",
      completed_at: DateTime.add(DateTime.utc_now(), -120, :second),
      completed_by_agent: "Claude"
    }

    Map.merge(base, overrides)
  end

  defp render_header(overrides \\ %{}, opts \\ []) do
    assigns = %{
      task: task(overrides),
      on_approve: Keyword.get(opts, :on_approve, "approve_review"),
      on_request_changes: Keyword.get(opts, :on_request_changes, "request_changes")
    }

    rendered_to_string(~H"""
    <ReviewDetailHeader.review_detail_header
      task={@task}
      on_approve={@on_approve}
      on_request_changes={@on_request_changes}
    />
    """)
  end

  describe "review_detail_header/1 — base rendering" do
    test "has the data-review-detail-header marker on the root" do
      assert render_header() =~ "data-review-detail-header"
    end

    test "renders the agent avatar via KanbanWeb.Avatar with kind :agent" do
      html = render_header()
      assert html =~ "border-radius: 4px"
      assert html =~ ~r/>\s*C\s*</
    end

    test "renders the completed_by_agent name" do
      assert render_header() =~ "Claude"
    end

    test "renders the 'completed' label" do
      assert render_header() =~ "completed"
    end

    test "renders the task identifier" do
      assert render_header() =~ "W101"
    end

    test "renders a relative age derived from completed_at" do
      html = render_header()
      assert html =~ "data-review-detail-header-time"
      assert html =~ ~r/(s|m|h|d) ago|just now/
    end
  end

  describe "review_detail_header/1 — action buttons" do
    test "renders two buttons: Request changes, Approve" do
      html = render_header()
      assert html =~ "Request changes"
      assert html =~ "Approve"
      # The View diff button was removed — no real diff data exists on Task
      # today, so the action would have been a no-op.
      refute html =~ "View diff"
      refute html =~ "data-review-detail-header-view-diff"
    end

    test "Request changes button has phx-click matching :on_request_changes attr" do
      html = render_header(%{}, on_request_changes: "request_changes_click")
      assert button_with_marker_has_phx_click?(html, "request-changes", "request_changes_click")
    end

    test "Approve button has phx-click matching :on_approve attr" do
      html = render_header(%{}, on_approve: "approve_click")
      assert button_with_marker_has_phx_click?(html, "approve", "approve_click")
    end

    test "uses the <.button> core component (btn class) for all actions" do
      html = render_header()
      # Two action buttons remain (Request changes + Approve) since View diff
      # was removed.
      assert length(Regex.scan(~r/class="btn[^"]*"/, html)) >= 2
    end

    test "Approve button uses btn-primary (no btn-soft) for dark-mode contrast" do
      html = render_header()

      approve_button =
        Regex.run(~r/<button[^>]*data-review-detail-header-approve[^>]*>/, html)
        |> List.first()

      assert approve_button =~ "btn-primary"
      refute approve_button =~ "btn-soft"
    end
  end

  defp button_with_marker_has_phx_click?(html, marker_suffix, event) do
    button =
      Regex.run(
        ~r/<button[^>]*data-review-detail-header-#{marker_suffix}[^>]*>/,
        html
      )
      |> List.first()

    button != nil and button =~ ~s(phx-click="#{event}")
  end

  describe "review_detail_header/1 — edge cases" do
    test "missing completed_by_agent renders neutral avatar and 'Unknown agent'" do
      html = render_header(%{completed_by_agent: nil})
      assert html =~ "Unknown agent"
      assert html =~ "data-review-detail-header"
    end

    test "empty-string completed_by_agent is treated as missing" do
      html = render_header(%{completed_by_agent: ""})
      assert html =~ "Unknown agent"
    end

    test "missing completed_at renders no age element (no 'nil ago')" do
      html = render_header(%{completed_at: nil})
      refute html =~ "data-review-detail-header-time"
      refute html =~ "nil ago"
    end
  end

  describe "review_detail_header/1 — completed_by user" do
    test "renders the human's display name and a mailto link when present" do
      html =
        render_header(%{
          completed_by: %{id: 99, name: "Alice Tester", email: "alice@example.com"}
        })

      assert html =~ "data-review-detail-header-completed-by"
      assert html =~ "data-review-detail-header-completed-by-name"
      assert html =~ "Alice Tester"
      assert html =~ ~s(href="mailto:alice@example.com")
      # Tooltip drives the icon-only mailto.
      assert html =~ ~s|title="Email Alice Tester"|
    end

    test "falls back to email when the user has no display name" do
      html =
        render_header(%{
          completed_by: %{id: 99, name: nil, email: "bob@example.com"}
        })

      # The display-name span shows the email, the mailto href still works.
      assert html =~ "bob@example.com"
      assert html =~ ~s(href="mailto:bob@example.com")
    end

    test "omits the completed-by row entirely when completed_by is nil" do
      html = render_header(%{completed_by: nil})
      refute html =~ "data-review-detail-header-completed-by"
    end

    test "renders the name but no mailto link when the user has no email" do
      html =
        render_header(%{
          completed_by: %{id: 99, name: "Carol Coder", email: nil}
        })

      assert html =~ "Carol Coder"
      refute html =~ "mailto:"
    end
  end
end
