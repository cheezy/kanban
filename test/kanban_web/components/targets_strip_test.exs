defmodule KanbanWeb.TargetsStripTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TargetsStrip.targets_strip/1` — the
  boards-page rail of delivery-target cards. Pure rendered_to_string
  tests, mirroring `KanbanWeb.GoalsStripTest`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TargetsStrip

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        target: %{name: "Q3 Launch", target_date: ~D[2026-12-31]},
        status: :on_track,
        completed: 12,
        total: 20,
        percentage: 60
      },
      overrides
    )
  end

  defp render_targets(targets) do
    assigns = %{targets: targets}

    rendered_to_string(~H"""
    <TargetsStrip.targets_strip targets={@targets} />
    """)
  end

  describe "targets_strip/1 — empty list" do
    test "renders nothing when the targets list is empty" do
      html = render_targets([])

      refute html =~ "data-target-card"
      refute html =~ ~s(class="ucase")
    end
  end

  describe "targets_strip/1 — header" do
    test "renders the Targets label with the count" do
      html =
        render_targets([
          entry(),
          entry(%{target: %{name: "Beta", target_date: ~D[2026-11-01]}})
        ])

      assert html =~ "Targets"
      assert html =~ ~r/class="ident"[^>]*>\s*2\s*</
    end
  end

  describe "targets_strip/1 — target card" do
    test "renders the name, formatted date and the N/M (P%) fraction" do
      html = render_targets([entry(%{completed: 12, total: 20, percentage: 60})])

      assert html =~ "data-target-card"
      assert html =~ "Q3 Launch"
      assert html =~ "Dec 31, 2026"
      assert html =~ ~r/12\/20 \(60%\)/
      assert html =~ "width: 60%"
    end

    test "renders a 0/0 (0%) fraction with a zero-width fill when there are no children" do
      html = render_targets([entry(%{completed: 0, total: 0, percentage: 0})])

      assert html =~ ~r/0\/0 \(0%\)/
      assert html =~ "width: 0%"
    end
  end

  describe "targets_strip/1 — status badge palette" do
    test "complete maps to --st-done / Complete" do
      html = render_targets([entry(%{status: :complete})])

      assert html =~ "Complete"
      assert html =~ "background: var(--st-done-soft); color: var(--st-done);"
      assert html =~ "background: var(--st-done);"
    end

    test "on_track maps to --st-ready / On-track" do
      html = render_targets([entry(%{status: :on_track})])

      assert html =~ "On-track"
      assert html =~ "background: var(--st-ready-soft); color: var(--st-ready);"
      assert html =~ "background: var(--st-ready);"
    end

    test "at_risk maps to --st-doing / At-risk" do
      html = render_targets([entry(%{status: :at_risk})])

      assert html =~ "At-risk"
      assert html =~ "background: var(--st-doing-soft); color: var(--st-doing);"
      assert html =~ "background: var(--st-doing);"
    end

    test "missed maps to --st-blocked / Missed" do
      html = render_targets([entry(%{status: :missed})])

      assert html =~ "Missed"
      assert html =~ "background: var(--st-blocked-soft); color: var(--st-blocked);"
      assert html =~ "background: var(--st-blocked);"
    end
  end
end
