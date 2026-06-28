defmodule KanbanWeb.GoalSidebarTest do
  @moduledoc """
  Contract tests for `KanbanWeb.GoalSidebar.goal_sidebar/1` — the
  right-rail metric pack rendered on the per-goal view page.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.GoalSidebar

  defp metrics(overrides \\ %{}) do
    Map.merge(
      %{
        percent: 38,
        done: 3,
        total: 8,
        in_flight: 2,
        ready: 1,
        backlog: 2,
        blocked: 0,
        contributor_count: 4,
        days_in_flight: 5,
        time_spent_minutes: 250,
        avg_cycle_minutes: 83,
        last_activity: ~U[2026-05-15 12:00:00Z],
        sparkline_data: [0, 1, 0, 2, 1, 1, 0, 2, 3, 1, 2, 0],
        sparkline_label: "May 03 — May 15",
        sparkline_unit: :day
      },
      overrides
    )
  end

  describe "goal_sidebar/1 — markers + scope" do
    test "outermost element carries data-goal-sidebar and scopes under .stride-screen" do
      assigns = %{metrics: metrics()}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "data-goal-sidebar"
      # Scoped under .stride-screen for token resolution; also carries the
      # goal-detail-aside class that the app.css <1024px rule targets to stack
      # the sidebar full-width below the hierarchy on mobile (W1392).
      assert html =~ "stride-screen"
      assert html =~ "goal-detail-aside"
    end

    test "renders the velocity sub-block with data-goal-velocity marker" do
      assigns = %{metrics: metrics()}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "data-goal-velocity"
    end
  end

  describe "goal_sidebar/1 — throughput heading + label" do
    test "uses the 'last 12 days' heading for the :day unit" do
      assigns = %{metrics: metrics(%{sparkline_unit: :day})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Throughput · last 12 days"
    end

    test "uses the 'last 12 hours' heading for the :hour unit" do
      assigns = %{metrics: metrics(%{sparkline_unit: :hour, sparkline_label: "08:00 — 20:00"})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Throughput · last 12 hours"
      assert html =~ "08:00 — 20:00"
    end

    test "renders the caller-supplied range label verbatim" do
      assigns = %{metrics: metrics(%{sparkline_label: "Mar 01 — Mar 13"})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Mar 01 — Mar 13"
    end
  end

  describe "goal_sidebar/1 — Progress section" do
    test "renders the headline percent + 'Complete' label" do
      assigns = %{metrics: metrics(%{percent: 72})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "72%"
      assert html =~ "Complete"
    end

    test "renders done/total in the canonical 'X/Y' shape" do
      assigns = %{metrics: metrics(%{done: 5, total: 12})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "5/12"
    end

    test "renders in-flight count in the doing tone" do
      assigns = %{metrics: metrics(%{in_flight: 4})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "In flight"
      assert html =~ "color: var(--st-doing)"
    end

    test "renders Ready count in the ready tone" do
      assigns = %{metrics: metrics(%{ready: 2})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Ready"
      assert html =~ "color: var(--st-ready)"
    end

    test "renders the Blocked row when blocked > 0" do
      assigns = %{metrics: metrics(%{blocked: 2})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/>\s*Blocked\s*</
      assert html =~ "color: var(--st-blocked)"
    end

    test "omits the Blocked row when blocked is 0" do
      assigns = %{metrics: metrics(%{blocked: 0})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      refute html =~ ~r/>\s*Blocked\s*</
    end

    test "renders Contributors count" do
      assigns = %{metrics: metrics(%{contributor_count: 7})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Contributors"
      assert html =~ ~r/>\s*7\s*</
    end
  end

  describe "goal_sidebar/1 — Time section" do
    test "renders 'today' when days_in_flight is 0" do
      assigns = %{metrics: metrics(%{days_in_flight: 0})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "today"
    end

    test "renders '1 day' when days_in_flight is 1" do
      assigns = %{metrics: metrics(%{days_in_flight: 1})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "1 day"
    end

    test "renders 'N days' when days_in_flight is greater than 1" do
      assigns = %{metrics: metrics(%{days_in_flight: 12})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "12 days"
    end

    test "renders '—' for nil days_in_flight" do
      assigns = %{metrics: metrics(%{days_in_flight: nil})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Days in flight"
      assert html =~ "—"
    end

    test "formats time_spent_minutes as Xh Ym" do
      assigns = %{metrics: metrics(%{time_spent_minutes: 95})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "1h 35m"
    end

    test "formats time_spent_minutes as Xh when remainder is 0" do
      assigns = %{metrics: metrics(%{time_spent_minutes: 120})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "2h"
    end

    test "formats time_spent_minutes below 60 as 'Nm'" do
      assigns = %{metrics: metrics(%{time_spent_minutes: 45, avg_cycle_minutes: nil})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/>\s*45m\s*</
    end

    test "renders '—' for zero time_spent_minutes" do
      assigns = %{metrics: metrics(%{time_spent_minutes: 0, avg_cycle_minutes: nil})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Time spent"
      assert html =~ "—"
    end

    test "renders '—' for nil avg_cycle_minutes" do
      assigns = %{metrics: metrics(%{avg_cycle_minutes: nil})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Avg cycle"
      assert html =~ "—"
    end
  end

  describe "goal_sidebar/1 — last_activity relative formatting" do
    test "renders 'Nm ago' for a DateTime in the recent past" do
      ten_min_ago = DateTime.utc_now() |> DateTime.add(-600, :second)
      assigns = %{metrics: metrics(%{last_activity: ten_min_ago})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/\d+m ago/
    end

    test "renders 'Nh ago' for a few-hours-old DateTime" do
      three_hours_ago = DateTime.utc_now() |> DateTime.add(-3 * 3600, :second)
      assigns = %{metrics: metrics(%{last_activity: three_hours_ago})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/\dh ago/
    end

    test "renders 'Nd ago' for a multi-day-old DateTime" do
      three_days_ago = DateTime.utc_now() |> DateTime.add(-3 * 86_400, :second)
      assigns = %{metrics: metrics(%{last_activity: three_days_ago})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/\dd ago/
    end

    test "renders 'just now' for an extremely recent timestamp" do
      assigns = %{metrics: metrics(%{last_activity: DateTime.utc_now()})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "just now"
    end

    test "accepts NaiveDateTime" do
      old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-600, :second)
      assigns = %{metrics: metrics(%{last_activity: old})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ ~r/\d+m ago/
    end

    test "renders '—' for nil last_activity" do
      assigns = %{metrics: metrics(%{last_activity: nil})}

      html =
        rendered_to_string(~H"""
        <GoalSidebar.goal_sidebar metrics={@metrics} />
        """)

      assert html =~ "Last activity"
      assert html =~ "—"
    end
  end
end
