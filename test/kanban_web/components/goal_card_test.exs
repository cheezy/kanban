defmodule KanbanWeb.GoalCardTest do
  @moduledoc """
  Contract tests for `KanbanWeb.GoalCard.goal_card/1` — the violet-tinted
  card variant for `task.type == :goal`. Covers the default violet
  treatment, custom goal-color overrides, the progress bar segments,
  the "Promote children to Ready" affordance, and the optional author
  avatar in the top-right slot.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.GoalCard

  defp goal_task(overrides \\ %{}) do
    Map.merge(
      %{
        id: 99,
        identifier: "G7",
        title: "Migrate the kanban page to the new design",
        type: :goal,
        priority: :high
      },
      overrides
    )
  end

  describe "goal_card/1 — default violet treatment" do
    test "renders the identifier, title, and GOAL pill" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "G7"
      assert html =~ "Migrate the kanban page to the new design"
      assert html =~ ~r/>\s*GOAL\s*</
    end

    test "defaults to var(--stride-violet*) tokens" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "background: var(--stride-violet-soft);"
      assert html =~ "border: 1px solid var(--stride-violet);"
      assert html =~ "box-shadow: var(--shadow-sm), inset 3px 0 0 var(--stride-violet);"
      assert html =~ "color: var(--stride-violet-ink);"
    end

    test "renders the flag-icon square in the goal color" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "hero-flag"
    end
  end

  describe "goal_card/1 — custom accent override" do
    test "honors goal_color / goal_soft / goal_ink when supplied" do
      assigns = %{
        task:
          goal_task(%{
            goal_color: "var(--stride-orange)",
            goal_soft: "var(--stride-orange-soft)",
            goal_ink: "var(--stride-orange-ink)"
          })
      }

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "background: var(--stride-orange-soft);"
      assert html =~ "border: 1px solid var(--stride-orange);"
      assert html =~ "color: var(--stride-orange-ink);"
      refute html =~ "var(--stride-violet-soft);"
    end
  end

  describe "goal_card/1 — summary" do
    test "renders the summary paragraph when present" do
      assigns =
        %{task: goal_task(%{summary: "Three weeks of work across 6 boards."})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "Three weeks of work across 6 boards."
    end

    test "falls back to description when summary is absent" do
      assigns =
        %{task: goal_task(%{description: "Falls back to description text."})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "Falls back to description text."
    end

    test "omits the summary paragraph when both summary and description are blank" do
      assigns = %{task: goal_task(%{summary: "   "})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      # No <p> tag for an empty summary
      refute html =~ ~r/<p[\s>]/
    end
  end

  describe "goal_card/1 — progress bar" do
    test "renders done/total and percent" do
      assigns =
        %{task: goal_task(%{children: %{done: 6, total: 10, review: 1, doing: 2, ready: 1}})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ ~r/>\s*6\/10\s*</
      assert html =~ "60%"
      assert html =~ "children complete"

      # W1392: the progress track uses the theme-aware --surface-sunken token
      # (not a hardcoded rgba(0,0,0,0.2) that was nearly invisible in dark mode).
      assert html =~ "background: var(--surface-sunken)"
      refute html =~ "rgba(0, 0, 0, 0.2)"
    end

    test "renders all four segment colors when each bucket has tasks" do
      assigns =
        %{task: goal_task(%{children: %{done: 4, total: 12, review: 2, doing: 3, ready: 3}})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "background: var(--st-done);"
      assert html =~ "background: var(--st-review);"
      assert html =~ "background: var(--st-doing);"
      assert html =~ "background: var(--st-ready);"
    end

    test "0/0 children renders 0% without dividing by zero" do
      assigns =
        %{task: goal_task(%{children: %{done: 0, total: 0, review: 0, doing: 0, ready: 0}})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ ~r/>\s*0\/0\s*</
      assert html =~ "0%"
    end

    test "omits the progress section entirely when children is nil" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      refute html =~ "children complete"
    end
  end

  describe "goal_card/1 — promote button" do
    test "renders the promote button by default (not yet promoted)" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "Promote children to Ready"
    end

    test "hides the promote button when promoted is true" do
      assigns = %{task: goal_task(%{promoted: true})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      refute html =~ "Promote children to Ready"
    end
  end

  describe "goal_card/1 — author avatar" do
    test "renders the author avatar at size=16 when supplied" do
      assigns =
        %{task: goal_task(%{author: %{kind: :human, name: "Jamie K", palette: "human-green"}})}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "width: 16px; height: 16px"
      assert html =~ "background: oklch(60% 0.10 155);"
    end

    test "omits the avatar slot when no author is supplied" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      # The Avatar component renders with a distinctive class set; the
      # 16x16 flag-icon square uses different classes and remains.
      refute html =~ "text-white font-semibold"
    end
  end

  describe "goal_card/1 — priority dot" do
    for {level, css_var} <- [
          {:critical, "var(--pri-critical)"},
          {:high, "var(--pri-high)"},
          {:medium, "var(--pri-medium)"},
          {:low, "var(--pri-low)"}
        ] do
      test "#{level} → #{css_var}" do
        assigns = %{task: goal_task(%{priority: unquote(level)})}

        html =
          rendered_to_string(~H"""
          <GoalCard.goal_card task={@task} />
          """)

        assert html =~ "background: #{unquote(css_var)};"
      end
    end
  end

  describe "goal_card/1 — dense variant" do
    test "tightens padding for the dense variant" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} dense />
        """)

      assert html =~ "padding: 6px 8px 6px 12px"
    end

    test "uses regular padding when dense is false" do
      assigns = %{task: goal_task()}

      html =
        rendered_to_string(~H"""
        <GoalCard.goal_card task={@task} />
        """)

      assert html =~ "padding: 9px 11px 9px 14px"
    end
  end
end
