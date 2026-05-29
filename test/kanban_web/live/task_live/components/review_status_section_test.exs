defmodule KanbanWeb.TaskLive.Components.ReviewStatusSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.ReviewStatusSection

  describe "review_status_section/1 — known statuses" do
    test "renders pending with the yellow badge" do
      assigns = %{
        task: %{
          review_status: :pending,
          reviewed_by: nil,
          reviewed_at: nil,
          review_notes: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Pending"
      assert html =~ "var(--st-doing-soft)"
    end

    test "renders approved with reviewer name and timestamp" do
      assigns = %{
        task: %{
          review_status: :approved,
          reviewed_by: %{name: "Reviewer Name", email: "r@example.com"},
          reviewed_at: ~U[2026-05-15 09:30:00Z],
          review_notes: "LGTM"
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Approved"
      assert html =~ "var(--st-done-soft)"
      assert html =~ "Reviewer Name"
      assert html =~ "May 15, 2026"
      assert html =~ "LGTM"
    end

    test "falls back to email when the reviewer has no name" do
      assigns = %{
        task: %{
          review_status: :changes_requested,
          reviewed_by: %{name: nil, email: "noname@example.com"},
          reviewed_at: nil,
          review_notes: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Changes Requested"
      assert html =~ "var(--stride-orange-soft)"
      assert html =~ "noname@example.com"
    end

    test "renders rejected with the blocked-token badge" do
      assigns = %{
        task: %{
          review_status: :rejected,
          reviewed_by: nil,
          reviewed_at: nil,
          review_notes: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Rejected"
      assert html =~ "var(--st-blocked-soft)"
    end
  end

  # Reaches the catch-all clauses for review_status_badge_class/1,
  # review_status_badge_fallback_style/1, review_status_label/1, and
  # review_section_class/1 — the design's stride-screen fallback path.
  describe "review_status_section/1 — fallback styling for unknown status" do
    test "renders the Unknown label and the stride-screen fallback styles when status is nil" do
      assigns = %{
        task: %{
          review_status: nil,
          reviewed_by: nil,
          reviewed_at: nil,
          review_notes: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Unknown"
      # Fallback badge style replaces the daisyUI gray with stride-screen tokens.
      assert html =~ "background: var(--surface-sunken)"
      assert html =~ "color: var(--ink-3)"
      # Fallback section background uses the surface-sunken token instead of the
      # green/yellow/orange/red daisyUI palettes.
      assert html =~ "bg-[var(--surface-sunken)]"
    end

    test "renders the Unknown label for an unrecognized atom too" do
      assigns = %{
        task: %{
          review_status: :weird_value,
          reviewed_by: nil,
          reviewed_at: nil,
          review_notes: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <ReviewStatusSection.review_status_section task={@task} />
        """)

      assert html =~ "Unknown"
      assert html =~ "bg-[var(--surface-sunken)]"
    end
  end
end
