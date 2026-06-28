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

  describe "task_card/1 — blocked indicator" do
    test "renders the no-symbol icon + Blocked tooltip when status is :blocked" do
      assigns = %{task: task(%{status: :blocked})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "hero-no-symbol"
      assert html =~ ~s(data-tip="Blocked")
      assert html =~ ~s(aria-label="Blocked")
      assert html =~ "color: var(--st-blocked);"
    end

    test "does NOT render the blocked indicator when status is :in_progress" do
      assigns = %{task: task(%{status: :in_progress})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      refute html =~ ~s(aria-label="Blocked")
    end

    test "does NOT render the blocked indicator when status is absent" do
      # Defaults — no :status key at all
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      refute html =~ ~s(aria-label="Blocked")
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
    test ":doing column renders the planning meta (same as backlog/ready)" do
      assigns = %{
        task:
          task(%{
            key_files_count: 4,
            deps_count: 1,
            acceptance_count: 3
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:doing} />
        """)

      # Same fields as backlog/ready (per acceptance criteria override).
      assert html =~ ~r/>\s*4\s*</
      assert html =~ ~r/>\s*1\s*</
      assert html =~ ~r/>\s*3\s*</
      # Non-zero deps render in the blocked color.
      assert html =~ "color: var(--st-blocked);"
    end

    test ":review column renders reviewer verdict (criteria/issues/files)" do
      assigns = %{
        task:
          task(%{
            criteria_checked: 5,
            issues_found: 0,
            files_changed_count: 3
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      # ngettext renders "5 criteria" (plural form)
      assert html =~ "5 criteria"
      assert html =~ "0 issues"
      assert html =~ "3 files"
      # Zero issues = clean → done-green icon color
      assert html =~ "color: var(--st-done);"
    end

    test ":review column flips issues color to blocked when issues_found > 0" do
      assigns = %{
        task:
          task(%{
            criteria_checked: 5,
            issues_found: 2,
            files_changed_count: 3
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "2 issues"
      assert html =~ "color: var(--st-blocked);"
    end

    test ":review column shows self-reviewed badge when reviewer was skipped" do
      assigns = %{
        task:
          task(%{
            reviewer_skipped?: true,
            reviewer_skip_reason: "small_task_0_1_key_files"
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "self-reviewed"
      # Reason enum value mapped to a punchy label
      assert html =~ "small task"
    end

    test ":done column renders cycle time, files changed, and actual complexity" do
      assigns = %{
        task:
          task(%{
            cycle_time: "1h 47m",
            files_changed_count: 3,
            actual_complexity: :medium
          })
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:done} />
        """)

      assert html =~ "cycle 1h 47m"
      assert html =~ "3 files"
      assert html =~ "actual: medium"
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
      # review pill — gettext("review") may localize to "Review" via the fuzzy
      # merge; match case-insensitively so the test survives translation churn.
      assert html =~ ~r/>\s*[Rr]eview\s*</
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

      # GoalCard renders the violet GOAL pill — a clean signal that the
      # delegation branch was taken without coupling to internal markup
      # of the regular task card.
      assert html =~ ~r/>\s*GOAL\s*</
      assert html =~ "var(--stride-violet)"
    end

    test "does NOT delegate when task.type is not :goal" do
      assigns = %{task: task(%{type: :work})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      refute html =~ ~r/>\s*GOAL\s*</
    end
  end

  describe "task_card/1 — helper fallbacks" do
    test "unknown priority falls back to ink-4" do
      assigns = %{task: task(%{priority: :urgent_unknown})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "background: var(--ink-4);"
    end

    test "goal value without a :color key falls back to the default 1px border" do
      assigns = %{task: task(%{goal: %{id: 99, name: "Loose goal"}})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ "border-left: 1px solid var(--line);"
    end
  end

  describe "task_card/1 — review skip reasons" do
    for {reason, label} <- [
          {"decision_matrix_skip", "decision matrix"},
          {"trivial_change_docs_only", "trivial change"},
          {"self_reported_exploration", "self-explored"},
          {"self_reported_review", "self-reviewed"},
          {"no_subagent_support", "no subagent"}
        ] do
      test "renders the punchy label for #{reason}" do
        assigns = %{
          task: task(%{reviewer_skipped?: true, reviewer_skip_reason: unquote(reason)})
        }

        html =
          rendered_to_string(~H"""
          <TaskCard.task_card task={@task} column={:review} />
          """)

        assert html =~ unquote(label)
      end
    end

    test "passes through an unknown reason string unchanged" do
      assigns = %{
        task: task(%{reviewer_skipped?: true, reviewer_skip_reason: "future_enum_value"})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      assert html =~ "future_enum_value"
    end

    test "renders empty string when reason is not a binary" do
      assigns = %{
        task: task(%{reviewer_skipped?: true, reviewer_skip_reason: nil})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} column={:review} />
        """)

      # No skip-reason text means just the self-reviewed badge with no
      # trailing label — assert the badge is present without a reason word.
      assert html =~ "self-reviewed"
    end
  end

  describe "task_card/1 — goal chip navigation" do
    test "renders the goal chip with phx-click=\"open_goal\" when board_id is set" do
      assigns = %{
        task: task(%{goal: %{id: 7, identifier: "G7", name: "Detail surface"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} board_id={99} />
        """)

      assert html =~ ~s(data-goal-chip)
      assert html =~ ~s(phx-click="open_goal")
      assert html =~ ~s(phx-value-board-id="99")
      assert html =~ ~s(phx-value-goal-id="7")
      assert html =~ "cursor: pointer;"
    end

    test "omits phx-click on the goal chip when board_id is nil" do
      assigns = %{
        task: task(%{goal: %{id: 7, identifier: "G7", name: "Detail surface"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      assert html =~ ~s(data-goal-chip)
      refute html =~ ~s(phx-click="open_goal")
    end

    test "omits phx-click when the goal has no :id" do
      assigns = %{
        task: task(%{goal: %{identifier: "G7", name: "Lite chip"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} board_id={99} />
        """)

      assert html =~ ~s(data-goal-chip)
      refute html =~ ~s(phx-click="open_goal")
    end
  end

  # W1389: the card must fill its column rather than impose a fixed width, and
  # must not clip its content — long titles wrap via the inner flex min-width:0
  # and tooltips escape because the card overflow is visible. These guard the
  # "no horizontal overflow" / mobile-card responsive criteria.
  describe "task_card/1 — responsive (W1389)" do
    test "the card article is a flex column that flows to its container, not clipped" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      # overflow: visible lets tooltip bubbles escape the card (pairs with the
      # #columns overflow-y: visible rule) and prevents content clipping.
      assert html =~ "overflow: visible"
      # The card is a flex column with no width declaration, so it fills the
      # column it sits in rather than imposing a fixed width that would overflow
      # a phone-width column.
      assert html =~ "display: flex"
      assert html =~ "flex-direction: column"
    end

    test "long titles wrap within the card instead of forcing it wide" do
      long_title =
        "An extremely long task title that would overflow a narrow phone-width column if it were not allowed to wrap"

      assigns = %{task: task(%{title: long_title})}

      html =
        rendered_to_string(~H"""
        <TaskCard.task_card task={@task} />
        """)

      # The long title renders in full...
      assert html =~ long_title
      # ...inside a flex:1 / min-width:0 container, which is what lets it wrap
      # within the card rather than pushing the layout wider than the column.
      assert html =~ "flex: 1; min-width: 0"
    end
  end
end
