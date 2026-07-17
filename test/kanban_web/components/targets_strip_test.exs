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
        target: %{id: 1, name: "Q3 Launch", target_date: ~D[2026-12-31]},
        status: :on_track,
        completed: 12,
        total: 20,
        percentage: 60,
        estimated_completion_date: nil
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

  defp count_dividers(html) do
    html |> String.split("data-pill-divider") |> length() |> Kernel.-(1)
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
          entry(%{target: %{id: 2, name: "Beta", target_date: ~D[2026-11-01]}})
        ])

      assert html =~ "Targets"
      assert html =~ ~r/class="ident"[^>]*>\s*2\s*</
    end
  end

  describe "targets_strip/1 — target card" do
    test "renders the name, formatted date and the N/M (P%) fraction" do
      html = render_targets([entry(%{completed: 12, total: 20, percentage: 60})])

      assert html =~ "data-target-card"
      assert html =~ ~s(href="/targets/1")
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

    test "separates the value clusters with three pill-scale dividers" do
      html = render_targets([entry()])

      assert html =~ "width: 1px; height: 15px; background: var(--ink-4);"
      assert count_dividers(html) == 3
    end
  end

  describe "targets_strip/1 — estimated completion date" do
    test "renders the estimate next to the target date when present" do
      html = render_targets([entry(%{estimated_completion_date: ~D[2027-03-03]})])

      assert html =~ "data-estimated-date"
      assert html =~ "Est. Mar 3, 2027"
      assert html =~ "Estimated completion"
      # The target's own date still renders — the estimate sits next to it,
      # behind its own conditional separator (3 cluster dividers + 1).
      assert html =~ "Dec 31, 2026"
      assert count_dividers(html) == 4
    end

    test "de-emphasizes the estimate relative to the fixed target date" do
      html = render_targets([entry(%{estimated_completion_date: ~D[2027-03-03]})])

      assert html =~ "font-style: italic; opacity: 0.75;"
      # 3 cluster dividers + the conditional separator between the dates.
      assert count_dividers(html) == 4
    end

    test "renders no estimate markup at all when the value is nil" do
      html = render_targets([entry()])

      refute html =~ "data-estimated-date"
      refute html =~ "Est."
      refute html =~ "font-style: italic"
      # No dangling divider where the estimate would sit.
      assert count_dividers(html) == 3
    end

    test "tolerates an entry missing the key entirely" do
      html = render_targets([Map.delete(entry(), :estimated_completion_date)])

      assert html =~ "data-target-card"
      refute html =~ "data-estimated-date"
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
