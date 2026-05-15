defmodule KanbanWeb.TaskMetadataGridTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TaskMetadataGrid.metadata_grid/1` — the
  120/1fr label/value rail shown on the task detail surface.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskMetadataGrid

  defp task(overrides \\ %{}) do
    Map.merge(
      %{
        type: :work,
        status: :ready,
        priority: :high,
        complexity: :large,
        needs_review: false,
        column: %{name: "Ready"},
        assigned_to: %{kind: :human, name: "Jamie K", palette: "human-green"},
        created_by: nil,
        inserted_at: ~U[2026-05-01 10:00:00Z],
        claimed_at: ~U[2026-05-02 11:00:00Z],
        completed_at: nil
      },
      overrides
    )
  end

  describe "metadata_grid/1 — base render" do
    test "renders all expected rows for a work task" do
      assigns = %{task: task(), parent_goal: nil, board_name: "Stride core"}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid
          task={@task}
          parent_goal={@parent_goal}
          board_name={@board_name}
        />
        """)

      assert html =~ "data-metadata-grid"
      assert html =~ "Status"
      assert html =~ "Column"
      assert html =~ "Board"
      assert html =~ "Stride core"
      assert html =~ "Author"
      assert html =~ "Complexity"
      assert html =~ "Large"
      assert html =~ "Priority"
      assert html =~ "High"
      assert html =~ "Needs review"
      assert html =~ "Created"
      assert html =~ "Started"
      assert html =~ "May 01, 2026"
    end
  end

  describe "metadata_grid/1 — defect type" do
    test "renders the same complexity/priority rows for :defect (severity/reproduction not yet on schema)" do
      assigns = %{
        task: task(%{type: :defect}),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ "Priority"
      assert html =~ "Complexity"
    end
  end

  describe "metadata_grid/1 — goal type" do
    test "omits the Complexity and Priority rows for :goal" do
      assigns = %{task: task(%{type: :goal}), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Complexity\s*</
      refute html =~ ~r/>\s*Priority\s*</
    end
  end

  describe "metadata_grid/1 — parent goal row" do
    test "omits the Goal row when parent_goal is nil" do
      assigns = %{task: task(), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Goal\s*</
    end

    test "renders the goal identifier and title when parent_goal is set" do
      assigns = %{
        task: task(),
        parent_goal: %{identifier: "G122", title: "Update the Task detail surface"},
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ ~r/>\s*Goal\s*</
      assert html =~ "G122"
      assert html =~ "Update the Task detail surface"
      assert html =~ "hero-flag"
    end
  end

  describe "metadata_grid/1 — owner avatar" do
    test "renders the assigned_to avatar when present" do
      assigns = %{task: task(), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      # Avatar component renders the human-green oklch swatch.
      assert html =~ "oklch(60% 0.10 155)"
      assert html =~ "Jamie K"
    end

    test "falls back to created_by when assigned_to is nil" do
      assigns = %{
        task:
          task(%{
            assigned_to: nil,
            created_by: %{kind: :human, name: "Pat S", palette: "human-blue"}
          }),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ "Pat S"
    end

    test "omits the Author row when both assigned_to and created_by are nil" do
      assigns = %{
        task: task(%{assigned_to: nil, created_by: nil}),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Author\s*</
    end

    test "tolerates an unloaded assigned_to association" do
      assigns = %{
        task:
          task(%{
            assigned_to: %Ecto.Association.NotLoaded{},
            created_by: nil
          }),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Author\s*</
    end
  end

  describe "metadata_grid/1 — timestamps" do
    test "omits Started when claimed_at is nil" do
      assigns = %{
        task: task(%{claimed_at: nil}),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Started\s*</
    end

    test "omits Completed when completed_at is nil" do
      assigns = %{task: task(), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      refute html =~ ~r/>\s*Completed\s*</
    end

    test "renders Completed when completed_at is present" do
      assigns = %{
        task: task(%{completed_at: ~U[2026-05-03 14:30:00Z]}),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ ~r/>\s*Completed\s*</
      assert html =~ "May 03, 2026"
    end

    test "accepts NaiveDateTime as well as DateTime" do
      assigns = %{
        task: task(%{inserted_at: ~N[2026-04-15 09:00:00]}),
        parent_goal: nil,
        board_name: nil
      }

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ "April 15, 2026"
    end
  end

  describe "metadata_grid/1 — status pill" do
    for {status, label, soft, ink} <- [
          {:open, "Open", "var(--st-backlog-soft)", "var(--st-backlog)"},
          {:ready, "Ready", "var(--st-ready-soft)", "var(--st-ready)"},
          {:in_progress, "Doing", "var(--st-doing-soft)", "var(--st-doing)"},
          {:review, "Review", "var(--st-review-soft)", "var(--st-review)"},
          {:completed, "Done", "var(--st-done-soft)", "var(--st-done)"}
        ] do
      test "status=#{status} renders #{label} with the matching token pair" do
        assigns = %{task: task(%{status: unquote(status)}), parent_goal: nil, board_name: nil}

        html =
          rendered_to_string(~H"""
          <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
          """)

        assert html =~ unquote(label)
        assert html =~ "background: #{unquote(soft)};"
        assert html =~ "color: #{unquote(ink)};"
      end
    end
  end

  describe "metadata_grid/1 — needs review cell" do
    test "renders the Required pill when needs_review is true" do
      assigns = %{task: task(%{needs_review: true}), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ "Required"
      assert html =~ "var(--st-review-soft)"
    end

    test "renders the Auto muted cell when needs_review is false" do
      assigns = %{task: task(%{needs_review: false}), parent_goal: nil, board_name: nil}

      html =
        rendered_to_string(~H"""
        <TaskMetadataGrid.metadata_grid task={@task} parent_goal={@parent_goal} />
        """)

      assert html =~ ~r/>\s*Auto\s*</
    end
  end
end
