defmodule KanbanWeb.AgentsHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.AgentsHeader.header/1` — the header band
  above the two-column body of the Agents view.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.AgentsHeader

  defp stats(overrides \\ %{}) do
    Map.merge(
      %{
        claimed_today: 0,
        completed_today: 0,
        approved_today: 0,
        avg_cycle_minutes: 0.0
      },
      overrides
    )
  end

  defp fleet_health(overrides \\ %{}) do
    Map.merge(%{working: 0, waiting: 0, stuck: 0, idle: 0}, overrides)
  end

  defp render(
         stats,
         event_count_24h,
         fleet_health \\ %{working: 0, waiting: 0, stuck: 0, idle: 0}
       ) do
    assigns = %{stats: stats, event_count_24h: event_count_24h, fleet_health: fleet_health}

    rendered_to_string(~H"""
    <AgentsHeader.header
      stats={@stats}
      fleet_health={@fleet_health}
      event_count_24h={@event_count_24h}
    />
    """)
  end

  describe "header/1 — markers and title" do
    test "outermost element carries data-agents-header and class stride-screen" do
      html = render(stats(), 0)

      assert html =~ "data-agents-header"
      assert html =~ ~s(class="stride-screen")
    end

    test "renders the H1 with the gettext title" do
      html = render(stats(), 0)

      assert html =~ ~r/<h1[^>]*>\s*Agent activity\s*<\/h1>/
    end
  end

  describe "header/1 — subtitle pluralization" do
    test "renders the singular subtitle when there is exactly one event" do
      html = render(stats(), 1)

      assert html =~ "last 24h"
      assert html =~ "1 event"
      refute html =~ "events"
    end

    test "renders the plural subtitle when there are multiple events" do
      html = render(stats(), 42)

      assert html =~ "42 events"
    end

    test "renders the plural subtitle when there are zero events" do
      html = render(stats(), 0)

      assert html =~ "0 events"
    end
  end

  describe "header/1 — KV stat cards" do
    test "renders the four KV cards in the configured order" do
      html = render(stats(%{claimed_today: 3, completed_today: 5, approved_today: 2}), 0)

      assert html =~ ~s(data-agents-header-kv="claimed-today")
      assert html =~ ~s(data-agents-header-kv="completed-today")
      assert html =~ ~s(data-agents-header-kv="approved-today")
      assert html =~ ~s(data-agents-header-kv="cycle-time")

      # Order matters — the claimed marker must precede the completed one
      claimed_pos = :binary.match(html, "claimed-today") |> elem(0)
      completed_pos = :binary.match(html, "completed-today") |> elem(0)
      approved_pos = :binary.match(html, "approved-today") |> elem(0)
      cycle_pos = :binary.match(html, "cycle-time") |> elem(0)

      assert claimed_pos < completed_pos
      assert completed_pos < approved_pos
      assert approved_pos < cycle_pos
    end

    test "renders the stat values inside the value <dd> cells" do
      html = render(stats(%{claimed_today: 7, completed_today: 4, approved_today: 1}), 0)

      assert html =~ ~r{<dd[^>]*>\s*7\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*4\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*1\s*</dd>}
    end

    test "renders the stat values at 24px to match the Delivery-trends values" do
      html = render(stats(%{claimed_today: 7}), 0)

      # The kv value <dd> uses the 24px size (matching trend_stat/1).
      assert html =~ ~r{<dd[^>]*font-size: 24px[^>]*>\s*7\s*</dd>}
      # The h1 and fleet-health values are untouched (still 18px).
      assert html =~ "font-size: 18px"
    end

    test "applies the doing/review/done tone CSS variables to the correct cards" do
      html = render(stats(%{claimed_today: 1, completed_today: 1, approved_today: 1}), 0)

      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-done)"
    end

    test "value cells use tabular-nums for alignment" do
      html = render(stats(), 0)

      assert html =~ "font-variant-numeric: tabular-nums"
    end

    test "renders the gettext labels with UCASE styling" do
      html = render(stats(), 0)

      assert html =~ "Claimed today"
      assert html =~ "Completed today"
      assert html =~ "Approved today"
      assert html =~ "Cycle time · today"
      assert html =~ "text-transform: uppercase"
      assert html =~ "letter-spacing: 0.08em"
    end
  end

  describe "header/1 — cycle-time formatting" do
    test "renders an em-dash when avg_cycle_minutes is nil" do
      html = render(stats(%{avg_cycle_minutes: nil}), 0)

      assert html =~ ~r/<dd[^>]*>\s*—\s*<\/dd>/u
    end

    test "renders an em-dash when avg_cycle_minutes is zero" do
      html = render(stats(%{avg_cycle_minutes: 0}), 0)

      assert html =~ ~r/<dd[^>]*>\s*—\s*<\/dd>/u
    end

    test "renders minutes only for sub-hour durations" do
      html = render(stats(%{avg_cycle_minutes: 42.0}), 0)

      assert html =~ "42m"
    end

    test "renders hours and minutes for durations of 60+ minutes" do
      html = render(stats(%{avg_cycle_minutes: 95.0}), 0)

      assert html =~ "1h 35m"
    end
  end

  describe "header/1 — visual styling" do
    test "uses var(--line) for the border-bottom" do
      html = render(stats(), 0)

      assert html =~ "border-bottom: 1px solid var(--line)"
    end
  end

  describe "header/1 — fleet-health rollup" do
    test "renders the four status counts in the rollup" do
      html =
        render(stats(), 0, fleet_health(%{working: 3, waiting: 2, stuck: 1, idle: 4}))

      assert html =~ "data-agents-fleet-health"
      assert html =~ ~s(data-agents-fleet-health-stat="working")
      assert html =~ ~s(data-agents-fleet-health-stat="waiting")
      assert html =~ ~s(data-agents-fleet-health-stat="stuck")
      assert html =~ ~s(data-agents-fleet-health-stat="idle")
    end

    test "renders gettext-wrapped labels for each status" do
      html = render(stats(), 0, fleet_health())

      assert html =~ "Working"
      assert html =~ "Waiting"
      assert html =~ "Stuck"
      assert html =~ "Idle"
    end

    test "emphasizes stuck and idle with soft-background design tokens" do
      html = render(stats(), 0, fleet_health(%{stuck: 2, idle: 5}))

      # stuck uses the blocked/danger palette; idle the brand-orange palette
      assert html =~ "var(--st-blocked-soft)"
      assert html =~ "var(--st-blocked)"
      assert html =~ "var(--stride-orange-soft)"
      assert html =~ "var(--stride-orange-ink)"
    end

    test "working and waiting stay as plain cards (no soft pill background)" do
      html = render(stats(), 0, fleet_health(%{working: 1, waiting: 1}))

      # working uses the doing tone; waiting the muted ink — neither gets a soft bg
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--ink-3)"
    end
  end
end
