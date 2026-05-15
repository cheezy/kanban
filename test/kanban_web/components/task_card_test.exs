defmodule KanbanWeb.TaskCardTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TaskCard.task_card/1` — the rich kanban
  card tile. Covers per-column variants, priority-dot color, avatar
  precedence (claimed > column-aware completed > author), goal stripe,
  dense variant, and delegation to GoalCard for goal-type tasks.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskCard

  defp task(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        identifier: "W42",
        title: "Wire the new metric pipeline",
        type: :work,
        priority: :medium
      },
      overrides
    )
  end

  describe "task_card/1 — base render" do
    test "renders the identifier and title" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "W42"
      assert html =~ "Wire the new metric pipeline"
    end

    test "renders the type icon for :work (hero-document-text)" do
      assigns = %{task: task(%{type: :work})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "hero-document-text"
    end

    test "renders the type icon for :defect (hero-bug-ant)" do
      assigns = %{task: task(%{type: :defect})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "hero-bug-ant"
    end
  end

  describe "task_card/1 — priority dot" do
    for {level, css_var} <- [
          {:critical, "var(--pri-critical)"},
          {:high, "var(--pri-high)"},
          {:medium, "var(--pri-medium)"},
          {:low, "var(--pri-low)"}
        ] do
      test "#{level} → #{css_var}" do
        assigns = %{task: task(%{priority: unquote(level)})}

        html =
          rendered_to_string(~H"""
          <TaskCard.task_card task={@task} />
          """)

        assert html =~ "background: #{unquote(css_var)};"
      end
    end
  end

  describe "task_card/1 — avatar precedence" do
    test "renders the claimed_by avatar with size=16 when present" do
      assigns = %{
        task: task(%{claimed_by: %{kind: :agent, name: "Claude", palette: "agent-claude"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "width: 16px; height: 16px"
      # Agent claude amber palette
      assert html =~ "background: oklch(70% 0.16 47);"
    end

    test "renders completed_by avatar (size=16) when in :review column and no claimed_by" do
      assigns = %{
        task: task(%{completed_by: %{kind: :human, name: "Jamie K", palette: "human-green"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "width: 16px; height: 16px"
      assert html =~ "background: oklch(60% 0.10 155);"
    end

    test "renders completed_by avatar when in :done column" do
      assigns = %{
        task: task(%{completed_by: %{kind: :agent, name: "Cursor", palette: "agent-cursor"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:done} />
        """)

      assert html =~ "background: oklch(60% 0.16 240);"
    end

    test "does NOT render completed_by when not in :review/:done columns" do
      assigns = %{
        task: task(%{completed_by: %{kind: :agent, name: "Cursor", palette: "agent-cursor"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:doing} />
        """)

      refute html =~ "background: oklch(60% 0.16 240);"
    end

    test "falls back to author avatar when no claimed_by/completed_by" do
      assigns = %{
        task: task(%{author: %{kind: :human, name: "Pat S", palette: "human-blue"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "background: oklch(60% 0.10 240);"
    end

    test "renders no avatar when task has none of claimed_by/completed_by/author" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      refute html =~ "width: 16px; height: 16px"
    end
  end

  describe "task_card/1 — goal stripe" do
    test "renders 3px goal-colored left border when task.goal is set" do
      assigns = %{
        task:
          task(%{
            goal: %{
              identifier: "G7",
              short: "Pipeline rewrite",
              color: "var(--stride-orange)",
              ink: "var(--stride-orange-ink)"
            }
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "border-left: 3px solid var(--stride-orange);"
      # Goal chip text appears
      assert html =~ "G7"
      assert html =~ "Pipeline rewrite"
    end

    test "renders default 1px border when task.goal is nil" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "border-left: 1px solid var(--line);"
    end
  end

  describe "task_card/1 — dense variant" do
    test "default (non-dense) uses 8px 10px padding" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "padding: 8px 10px"
    end

    test "dense=true uses 6px 8px padding" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} dense />
        """)

      assert html =~ "padding: 6px 8px"
    end

    test "dense=true tightens the gap from 6px to 4px" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} dense />
        """)

      assert html =~ "gap: 4px"
    end
  end

  describe "task_card/1 — column-specific footers" do
    test ":doing column renders the hook chip with running animation" do
      assigns = %{
        task: task(%{hook: %{name: "after_doing", status: :running}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:doing} />
        """)

      assert html =~ "after_doing"
      assert html =~ "running"
      assert html =~ "var(--st-doing-soft)"
      assert html =~ "motion-safe:animate-spin"
    end

    test ":review column renders diff numbers and tests passed/total" do
      assigns = %{
        task:
          task(%{
            diff: %{added: 42, removed: 7},
            tests_passed: 12,
            tests_total: 12
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "+42"
      assert html =~ "−7"
      assert html =~ "12/12"
    end

    test ":review tests-failed coloring flips to blocked when passed < total" do
      assigns = %{
        task:
          task(%{
            diff: %{added: 1, removed: 1},
            tests_passed: 3,
            tests_total: 5
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "color: var(--st-blocked);"
    end

    test ":backlog column renders meta when present (non-dense)" do
      assigns = %{
        task:
          task(%{
            key_files_count: 3,
            deps_count: 2,
            acceptance_count: 5,
            needs_review: true
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:backlog} />
        """)

      assert html =~ ~r/>\s*3\s*</
      assert html =~ ~r/>\s*2\s*</
      assert html =~ ~r/>\s*5\s*</
      # review pill
      assert html =~ ~r/>\s*review\s*</
    end

    test ":done column renders cycle time when present" do
      assigns = %{task: task(%{cycle_time: "3h"})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:done} />
        """)

      assert html =~ "cycle 3h"
    end
  end

  describe "task_card/1 — goal-type delegation" do
    test "delegates to GoalCard for task.type == :goal" do
      assigns = %{task: task(%{type: :goal})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      # GoalCard stub (W533) marks itself with a data-attribute so the
      # delegation is observable from the test without coupling to its
      # full visual treatment (which W534 will add).
      assert html =~ ~s(data-goal-card-stub="true")
    end

    test "does NOT delegate when task.type is not :goal" do
      assigns = %{task: task(%{type: :work})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      refute html =~ ~s(data-goal-card-stub="true")
    end
  end
end
