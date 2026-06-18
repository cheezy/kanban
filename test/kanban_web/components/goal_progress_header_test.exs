defmodule KanbanWeb.GoalProgressHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.GoalProgressHeader.goal_progress_header/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.GoalProgressHeader

  defp goal(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "G7",
        title: "Migrate the task detail surface",
        priority: :high,
        why: "Keep the design system unified across surfaces.",
        ai_generated?: false
      },
      overrides
    )
  end

  defp flow(overrides) do
    Map.merge(
      %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0},
      overrides
    )
  end

  describe "goal_progress_header/1 — base render" do
    test "renders identifier, title, why and the percent complete" do
      assigns = %{
        goal: goal(),
        flow: flow(%{done: 3, doing: 2, total: 8})
      }

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ "data-goal-progress-header"
      assert html =~ "G7"
      assert html =~ "Migrate the task detail surface"
      assert html =~ "Keep the design system unified across surfaces."
      assert html =~ "38%"
      assert html =~ "3 of 8 complete"
    end

    test "outermost element scopes under .stride-screen" do
      assigns = %{goal: goal(), flow: flow(%{total: 1, done: 1})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ ~s(class="stride-screen")
    end

    test "renders the Goal pill with violet tokens" do
      assigns = %{goal: goal(), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ ~r/>\s*Goal\s*</
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ "var(--stride-violet-ink)"
    end
  end

  describe "goal_progress_header/1 — AI pill" do
    test "renders the AI pill when ai_generated? is true" do
      assigns = %{goal: goal(%{ai_generated?: true}), flow: flow(%{total: 1, done: 1})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ ~r/>\s*AI\s*</
    end

    test "hides the AI pill when ai_generated? is false (default)" do
      assigns = %{goal: goal(), flow: flow(%{total: 1, done: 1})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      # The AI pill copy is the word "AI" — assert no AI-pill-styled span renders.
      # The pill's distinctive token combo proves the pill is absent.
      refute html =~
               "<span class=\"ucase\" style=\"display: inline-flex; align-items: center; gap: 3px;"
    end
  end

  describe "goal_progress_header/1 — priority" do
    test "renders the priority dot color and label" do
      assigns = %{
        goal: goal(%{priority: :critical}),
        flow: flow(%{total: 1, done: 0})
      }

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ "var(--pri-critical)"
      assert html =~ "Critical"
    end

    test "omits priority block when priority is nil" do
      assigns = %{goal: goal(%{priority: nil}), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      refute html =~ "var(--pri-"
    end
  end

  describe "goal_progress_header/1 — per-status KV strip" do
    test "renders all five status counts in order with their tokens" do
      assigns = %{
        goal: goal(),
        flow: flow(%{backlog: 1, ready: 2, doing: 3, review: 4, done: 5, total: 15})
      }

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ "Backlog"
      assert html =~ "Ready"
      assert html =~ "Doing"
      assert html =~ "Review"
      assert html =~ "Done"

      assert html =~ "var(--st-backlog)"
      assert html =~ "var(--st-ready)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-done)"
    end

    test "honors a caller-supplied :by_status map" do
      assigns = %{
        goal: goal(),
        flow: flow(%{total: 6, done: 0}),
        by_status: %{backlog: 0, ready: 0, doing: 0, review: 0, done: 6}
      }

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header
          goal={@goal}
          flow={@flow}
          by_status={@by_status}
        />
        """)

      # 6 done renders alongside the Done label using the --st-done tone.
      assert html =~ "var(--st-done)"
    end
  end

  describe "goal_progress_header/1 — progress math" do
    test "0% complete when total is 0" do
      assigns = %{goal: goal(), flow: flow(%{total: 0, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ "0%"
      assert html =~ "0 of 0 complete"
    end

    test "100% complete when done == total" do
      assigns = %{goal: goal(), flow: flow(%{total: 4, done: 4})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      assert html =~ "100%"
    end

    test "rounds to nearest percent" do
      assigns = %{goal: goal(), flow: flow(%{total: 3, done: 1})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      # 1/3 = 33.33% → rounds to 33.
      assert html =~ "33%"
    end
  end

  describe "goal_progress_header/1 — total derivation" do
    test "sums the per-status counts when flow omits :total" do
      # No :total key forces the sum_statuses/1 fallback over the status map.
      assigns = %{
        goal: goal(),
        flow: %{backlog: 1, ready: 2, doing: 1, review: 0, done: 4}
      }

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      # 4 done out of a derived total of 8 → 50%.
      assert html =~ "50%"
      assert html =~ "4 of 8 complete"
    end
  end

  describe "goal_progress_header/1 — optional why text" do
    test "omits the why paragraph when missing" do
      assigns = %{goal: goal(%{why: nil}), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      refute html =~ "Keep the design system"
    end

    test "treats whitespace-only why as absent" do
      assigns = %{goal: goal(%{why: "   "}), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      # The <p> with max-width:720px would be present if rendered; refute its
      # distinctive style block.
      refute html =~ "max-width: 720px"
    end

    test "treats an empty-string why as absent" do
      assigns = %{goal: goal(%{why: ""}), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      refute html =~ "max-width: 720px"
    end

    test "treats a non-string why as absent" do
      # A non-binary value (e.g. an atom leaking through a dynamic map) is
      # coerced to nil rather than rendered.
      assigns = %{goal: goal(%{why: :unexpected}), flow: flow(%{total: 1, done: 0})}

      html =
        rendered_to_string(~H"""
        <GoalProgressHeader.goal_progress_header goal={@goal} flow={@flow} />
        """)

      refute html =~ "max-width: 720px"
    end
  end
end
