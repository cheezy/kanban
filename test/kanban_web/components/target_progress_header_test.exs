defmodule KanbanWeb.TargetProgressHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TargetProgressHeader.target_progress_header/1`
  — the delivery-target drill-down hero. Pure `rendered_to_string` tests,
  mirroring `KanbanWeb.GoalProgressHeaderTest` and `KanbanWeb.TargetsStripTest`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TargetProgressHeader

  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        target: %{name: "Q3 Launch", target_date: ~D[2026-12-31], description: nil},
        status: :on_track,
        completed: 3,
        total: 10,
        percentage: 30
      },
      overrides
    )
  end

  defp flow(overrides \\ %{}) do
    Map.merge(
      %{backlog: 2, ready: 2, doing: 2, review: 1, done: 3, total: 10},
      overrides
    )
  end

  defp render_header(summary, flow) do
    assigns = %{summary: summary, flow: flow}

    rendered_to_string(~H"""
    <TargetProgressHeader.target_progress_header summary={@summary} flow={@flow} />
    """)
  end

  describe "target_progress_header/1 — identity" do
    test "renders the target name, the Target pill and the formatted target date" do
      html = render_header(summary(), flow())

      assert html =~ "data-target-progress-header"
      assert html =~ "Q3 Launch"
      assert html =~ "Target"
      assert html =~ "Dec 31, 2026"
    end

    test "renders the description blurb when present" do
      html =
        render_header(
          summary(%{
            target: %{
              name: "Q3 Launch",
              target_date: ~D[2026-12-31],
              description: "Ship the launch"
            }
          }),
          flow()
        )

      assert html =~ "Ship the launch"
      assert html =~ "max-width: 720px"
    end

    test "omits the description blurb when blank" do
      html =
        render_header(
          summary(%{
            target: %{name: "Q3 Launch", target_date: ~D[2026-12-31], description: "   "}
          }),
          flow()
        )

      refute html =~ "max-width: 720px"
    end

    test "still renders the header when the target date is nil" do
      html =
        render_header(
          summary(%{target: %{name: "No Date Target", target_date: nil, description: nil}}),
          flow()
        )

      assert html =~ "data-target-progress-header"
      assert html =~ "No Date Target"
      # The date span is driven by :if={@target_date}, so nothing date-like renders.
      refute html =~ ~r/\b\d{4}\b/
    end
  end

  describe "target_progress_header/1 — progress" do
    test "renders the aggregate percentage and the N-of-M complete count" do
      html = render_header(summary(%{completed: 3, total: 10}), flow())

      assert html =~ "30%"
      assert html =~ "3 of 10 complete"
    end

    test "renders a large segmented progress bar fed by the aggregate flow" do
      html = render_header(summary(), flow())

      assert html =~ "data-segmented-progress"
      # size: :lg => 14px tall, full width
      assert html =~ "height: 14px"
    end

    test "re-derives the percentage from completed/total (guarding total == 0)" do
      html =
        render_header(
          summary(%{completed: 0, total: 0, percentage: 0}),
          flow(%{backlog: 0, ready: 0, doing: 0, review: 0, done: 0, total: 0})
        )

      assert html =~ "0%"
      assert html =~ "0 of 0 complete"
      # No division-by-zero crash; the bar still renders its track.
      assert html =~ "data-segmented-progress"
    end

    test "renders 100% for a fully complete target" do
      html =
        render_header(
          summary(%{status: :complete, completed: 10, total: 10, percentage: 100}),
          flow(%{backlog: 0, ready: 0, doing: 0, review: 0, done: 10, total: 10})
        )

      assert html =~ "100%"
      assert html =~ "10 of 10 complete"
    end

    test "renders the per-status KV strip counts from the flow" do
      html =
        render_header(
          summary(),
          flow(%{backlog: 2, ready: 2, doing: 2, review: 1, done: 3, total: 10})
        )

      assert html =~ "Backlog"
      assert html =~ "Ready"
      assert html =~ "Doing"
      assert html =~ "Review"
      assert html =~ "Done"
    end
  end

  describe "target_progress_header/1 — status badge palette" do
    test "complete maps to --st-done / Complete" do
      html = render_header(summary(%{status: :complete}), flow())

      assert html =~ "Complete"
      assert html =~ "background: var(--st-done-soft); color: var(--st-done);"
    end

    test "on_track maps to --st-ready / On-track" do
      html = render_header(summary(%{status: :on_track}), flow())

      assert html =~ "On-track"
      assert html =~ "background: var(--st-ready-soft); color: var(--st-ready);"
    end

    test "at_risk maps to --st-doing / At-risk" do
      html = render_header(summary(%{status: :at_risk}), flow())

      assert html =~ "At-risk"
      assert html =~ "background: var(--st-doing-soft); color: var(--st-doing);"
    end

    test "missed maps to --st-blocked / Missed" do
      html = render_header(summary(%{status: :missed}), flow())

      assert html =~ "Missed"
      assert html =~ "background: var(--st-blocked-soft); color: var(--st-blocked);"
    end
  end
end
