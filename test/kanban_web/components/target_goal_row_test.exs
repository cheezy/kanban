defmodule KanbanWeb.TargetGoalRowTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TargetGoalRow.target_goal_row/1` — the
  per-goal table row on the delivery-target drill-down. Pure
  `rendered_to_string` tests, mirroring `KanbanWeb.GoalChildRowTest`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TargetGoalRow

  defp entry(overrides \\ %{}) do
    goal_overrides = Map.get(overrides, :goal, %{})

    goal =
      Map.merge(
        %{
          id: 42,
          identifier: "G7",
          title: "Ship the delivery dashboard",
          priority: :high,
          column: %{board_id: 55},
          assigned_to: %{kind: :human, name: "Jamie K", palette: "human-green"}
        },
        goal_overrides
      )

    Map.merge(
      %{
        goal: goal,
        flow: %{backlog: 2, ready: 1, doing: 1, review: 1, done: 3, total: 8},
        completed: 3,
        total: 8,
        percentage: 38
      },
      Map.delete(overrides, :goal)
    )
  end

  defp render_row(entry) do
    assigns = %{entry: entry}

    rendered_to_string(~H"""
    <TargetGoalRow.target_goal_row entry={@entry} />
    """)
  end

  describe "target_goal_row/1 — base render" do
    test "renders identifier, title, progress bar, count, owner and chevron" do
      html = render_row(entry())

      assert html =~ "data-target-goal-row"
      assert html =~ "G7"
      assert html =~ "Ship the delivery dashboard"
      assert html =~ "data-segmented-progress"
      assert html =~ "3 of 8 (38%)"
      assert html =~ "Jamie K"
      assert html =~ "hero-chevron-right"
      assert html =~ ~s(data-goal-col="identifier")
      assert html =~ ~s(data-goal-col="owner")
    end

    test "truncates the title with an ellipsis" do
      html =
        render_row(
          entry(%{
            goal: %{
              title:
                "An extremely long goal title that should be truncated with an ellipsis so it fits"
            }
          })
        )

      assert html =~ "text-overflow: ellipsis;"
    end
  end

  describe "target_goal_row/1 — drill-down link" do
    test "links to /boards/:board_id/goals/:goal_id built from the goal's own board" do
      html = render_row(entry(%{goal: %{id: 42, column: %{board_id: 55}}}))

      assert html =~ ~s(href="/boards/55/goals/42")
    end

    test "uses the goal's own board_id, not a hardcoded one" do
      html = render_row(entry(%{goal: %{id: 9, column: %{board_id: 123}}}))

      assert html =~ ~s(href="/boards/123/goals/9")
    end
  end

  describe "target_goal_row/1 — progress" do
    test "re-derives 0% and does not crash for a goal with no child tasks" do
      html =
        render_row(
          entry(%{
            flow: %{backlog: 0, ready: 0, doing: 0, review: 0, done: 0, total: 0},
            completed: 0,
            total: 0,
            percentage: 0
          })
        )

      assert html =~ "0 of 0 (0%)"
      assert html =~ "data-segmented-progress"
    end

    test "renders a compact (:sm) segmented progress bar" do
      html = render_row(entry())

      # size: :sm => 96px wide, 10px tall
      assert html =~ "width: 96px"
    end

    test "renders 100% for a fully complete goal" do
      html =
        render_row(
          entry(%{
            flow: %{backlog: 0, ready: 0, doing: 0, review: 0, done: 5, total: 5},
            completed: 5,
            total: 5,
            percentage: 100
          })
        )

      assert html =~ "5 of 5 (100%)"
    end
  end

  describe "target_goal_row/1 — priority dot" do
    for {level, token} <- [
          {:critical, "var(--pri-critical)"},
          {:high, "var(--pri-high)"},
          {:medium, "var(--pri-medium)"},
          {:low, "var(--pri-low)"}
        ] do
      test "priority=#{level} colors the dot with #{token}" do
        html = render_row(entry(%{goal: %{priority: unquote(level)}}))

        assert html =~ "background: #{unquote(token)};"
      end
    end
  end

  describe "target_goal_row/1 — owner" do
    test "renders the avatar swatch and name when the goal is assigned" do
      html = render_row(entry())

      assert html =~ "oklch(60% 0.10 155)"
      assert html =~ "Jamie K"
    end

    test "renders 'unassigned' when the goal has no assignee" do
      html = render_row(entry(%{goal: %{assigned_to: nil}}))

      assert html =~ "unassigned"
      refute html =~ "Jamie K"
    end

    test "tolerates an unloaded assigned_to association" do
      html = render_row(entry(%{goal: %{assigned_to: %Ecto.Association.NotLoaded{}}}))

      assert html =~ "unassigned"
    end
  end

  describe "target_goal_row/1 — agent owner fallback (D132)" do
    test "renders the completing agent's name and a square agent avatar when unassigned" do
      html =
        render_row(entry(%{goal: %{assigned_to: nil, completed_by_agent: "Claude Sonnet 4.5"}}))

      assert html =~ "Claude Sonnet 4.5"
      # Agents render as 4px-radius squares (KanbanWeb.Avatar); humans as circles.
      assert html =~ "border-radius: 4px;"
      # agent-claude palette resolved via AvatarPalette.for_agent/1.
      assert html =~ "oklch(70% 0.16 47)"
      refute html =~ "unassigned"
    end

    test "falls back to created_by_agent when completed_by_agent is absent" do
      html = render_row(entry(%{goal: %{assigned_to: nil, created_by_agent: "Codex CLI"}}))

      assert html =~ "Codex CLI"
      assert html =~ "border-radius: 4px;"
      refute html =~ "unassigned"
    end

    test "skips a blank completed_by_agent and falls through to created_by_agent" do
      html =
        render_row(
          entry(%{goal: %{assigned_to: nil, completed_by_agent: "", created_by_agent: "Aider"}})
        )

      assert html =~ "Aider"
      refute html =~ "unassigned"
    end

    test "a human assignee wins over agent attribution" do
      html =
        render_row(
          entry(%{
            goal: %{
              completed_by_agent: "Claude Sonnet 4.5",
              created_by_agent: "Claude Sonnet 4.5"
            }
          })
        )

      assert html =~ "Jamie K"
      refute html =~ "Claude Sonnet 4.5"
      refute html =~ "border-radius: 4px;"
    end

    test "renders italic 'unassigned' when there is no user and no agent attribution" do
      html = render_row(entry(%{goal: %{assigned_to: nil}}))

      assert html =~ "unassigned"
      assert html =~ "font-style: italic;"
    end
  end
end
