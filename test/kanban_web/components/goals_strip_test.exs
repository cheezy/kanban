defmodule KanbanWeb.GoalsStripTest do
  @moduledoc """
  Contract tests for `KanbanWeb.GoalsStrip.goals_strip/1` — the
  horizontal active-goals rail above the kanban columns.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.GoalsStrip

  defp goal(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "G7",
        name: "Pipeline rewrite",
        color: "var(--stride-orange)",
        ink: "var(--stride-orange-ink)",
        flow: %{done: 4, review: 1, doing: 2, ready: 1, backlog: 2, total: 10},
        promoted: true
      },
      overrides
    )
  end

  describe "goals_strip/1 — empty list" do
    test "renders nothing visible when goals list is empty" do
      assigns = %{goals: []}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      refute html =~ "Active goals"
      refute html =~ "New goal"
    end
  end

  describe "goals_strip/1 — header" do
    test "renders the Active goals label with count" do
      assigns = %{goals: [goal(), goal(%{identifier: "G8", name: "Auth refresh"})]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "Active goals"
      # Count of 2
      assert html =~ ~r/class="ident"[^>]*>\s*2\s*</
    end

    test "does not render a New goal button (entry point lives in the board header)" do
      assigns = %{goals: [goal()]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      refute html =~ "New goal"
      refute html =~ "hero-plus"
    end
  end

  describe "goals_strip/1 — goal pill" do
    test "renders one pill per goal with identifier + name" do
      assigns = %{
        goals: [
          goal(%{identifier: "G7", name: "Pipeline"}),
          goal(%{identifier: "G8", name: "Refresh tokens"}),
          goal(%{identifier: "G9", name: "Spam filter"})
        ]
      }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "G7"
      assert html =~ "Pipeline"
      assert html =~ "G8"
      assert html =~ "Refresh tokens"
      assert html =~ "G9"
      assert html =~ "Spam filter"
    end

    test "applies the goal's color to the pill border + left stripe" do
      assigns = %{goals: [goal(%{color: "var(--stride-orange)"})]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "border: 1px solid var(--stride-orange);"
      assert html =~ "border-left: 3px solid var(--stride-orange);"
    end

    test "renders the done/total count" do
      assigns =
        %{
          goals: [
            goal(%{flow: %{done: 6, review: 1, doing: 2, ready: 1, backlog: 0, total: 10}})
          ]
        }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ ~r/>\s*6\/10\s*</
    end

    test "falls back to var(--stride-violet*) when goal lacks color/ink" do
      assigns = %{
        goals: [%{identifier: "G99", name: "No colors set", flow: %{total: 0}, promoted: true}]
      }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "border: 1px solid var(--stride-violet);"
      assert html =~ "color: var(--stride-violet-ink);"
    end
  end

  describe "goals_strip/1 — segmented progress bar" do
    test "renders only segments with count > 0" do
      assigns =
        %{
          goals: [
            goal(%{
              flow: %{done: 5, review: 0, doing: 3, ready: 0, backlog: 2, total: 10}
            })
          ]
        }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "background: var(--st-done);"
      assert html =~ "background: var(--st-doing);"
      assert html =~ "background: var(--st-backlog);"
      # Review and ready buckets are 0 — those segments should not render
      refute html =~ "background: var(--st-review);"
      refute html =~ "background: var(--st-ready);"
    end

    test "segment widths use flex proportional to count" do
      assigns =
        %{
          goals: [
            goal(%{flow: %{done: 4, review: 2, doing: 1, ready: 0, backlog: 0, total: 7}})
          ]
        }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "flex: 4;"
      assert html =~ "flex: 2;"
      assert html =~ "flex: 1;"
    end

    test "renders an empty bar (all 0) without crash" do
      assigns = %{
        goals: [
          %{
            identifier: "G0",
            name: "No work",
            color: "var(--stride-violet)",
            ink: "var(--stride-violet-ink)",
            flow: %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0},
            promoted: true
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      # No status-color segment spans rendered inside the bar
      refute html =~ "background: var(--st-done);"
      refute html =~ "background: var(--st-doing);"
      # But the bar container itself is still present
      assert html =~ "width: 96px"
    end
  end

  describe "goals_strip/1 — unpromoted pill" do
    test "renders the unpromoted badge when promoted is false" do
      assigns = %{goals: [goal(%{promoted: false})]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "unpromoted"
      assert html =~ "var(--st-backlog-soft)"
    end

    test "omits the unpromoted badge when promoted is true (default)" do
      assigns = %{goals: [goal()]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      refute html =~ "unpromoted"
    end
  end

  describe "goals_strip/1 — compact variant" do
    test "compact tightens outer padding" do
      assigns = %{goals: [goal()]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} compact />
        """)

      assert html =~ "padding: 8px 14px;"
    end

    test "default outer padding is roomy" do
      assigns = %{goals: [goal()]}

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "padding: 10px 22px 12px;"
    end
  end

  describe "goals_strip/1 — navigate-to-goal" do
    test "wraps the goal pill in a navigate link when a board is provided" do
      assigns = %{
        goals: [
          %{
            id: 42,
            identifier: "G7",
            name: "Migrate the detail surface",
            flow: %{done: 1, total: 1},
            promoted: true
          }
        ],
        board: %{id: 99, name: "Stride core"}
      }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} board={@board} />
        """)

      assert html =~ "data-goal-pill"
      assert html =~ ~s(href="/boards/99/goals/42")
      assert html =~ ~s(aria-label="Open goal G7")
    end

    test "renders the pill as a non-link div when board is nil" do
      assigns = %{
        goals: [
          %{
            id: 42,
            identifier: "G7",
            name: "No board",
            flow: %{done: 0, total: 1},
            promoted: true
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <GoalsStrip.goals_strip goals={@goals} />
        """)

      assert html =~ "data-goal-pill"
      refute html =~ "href=\"/boards/"
    end
  end
end
