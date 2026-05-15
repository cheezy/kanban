defmodule KanbanWeb.GoalChildRowTest do
  @moduledoc """
  Contract tests for `KanbanWeb.GoalChildRow.goal_child_row/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.GoalChildRow

  defp child(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1234,
        identifier: "W199",
        title: "Wire the metric pipeline",
        status: :ready,
        priority: :high,
        assigned_to: %{kind: :human, name: "Jamie K", palette: "human-green"}
      },
      overrides
    )
  end

  describe "goal_child_row/1 — base render" do
    test "renders identifier, title, status pill, and owner" do
      assigns = %{task: child()}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} />
        """)

      assert html =~ "data-goal-child-row"
      assert html =~ "W199"
      assert html =~ "Wire the metric pipeline"
      assert html =~ "Ready"
      assert html =~ "Jamie K"
      assert html =~ "hero-chevron-right"
    end
  end

  describe "goal_child_row/1 — status pill" do
    for {status, label, soft, ink} <- [
          {:open, "Open", "var(--st-backlog-soft)", "var(--st-backlog)"},
          {:ready, "Ready", "var(--st-ready-soft)", "var(--st-ready)"},
          {:in_progress, "Doing", "var(--st-doing-soft)", "var(--st-doing)"},
          {:review, "Review", "var(--st-review-soft)", "var(--st-review)"},
          {:completed, "Done", "var(--st-done-soft)", "var(--st-done)"}
        ] do
      test "status=#{status} renders #{label} with matching token pair" do
        assigns = %{task: child(%{status: unquote(status)})}

        html =
          rendered_to_string(~H"""
          <GoalChildRow.goal_child_row task={@task} />
          """)

        assert html =~ unquote(label)
        assert html =~ "background: #{unquote(soft)};"
        assert html =~ "color: #{unquote(ink)};"
      end
    end
  end

  describe "goal_child_row/1 — priority dot" do
    for {level, token} <- [
          {:critical, "var(--pri-critical)"},
          {:high, "var(--pri-high)"},
          {:medium, "var(--pri-medium)"},
          {:low, "var(--pri-low)"}
        ] do
      test "priority=#{level} colors the dot with #{token}" do
        assigns = %{task: child(%{priority: unquote(level)})}

        html =
          rendered_to_string(~H"""
          <GoalChildRow.goal_child_row task={@task} />
          """)

        assert html =~ "background: #{unquote(token)};"
      end
    end
  end

  describe "goal_child_row/1 — owner" do
    test "renders the avatar swatch and name when assigned_to is present" do
      assigns = %{task: child()}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} />
        """)

      # Avatar component renders the human-green oklch swatch.
      assert html =~ "oklch(60% 0.10 155)"
      assert html =~ "Jamie K"
    end

    test "renders 'unassigned' when assigned_to is nil" do
      assigns = %{task: child(%{assigned_to: nil})}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} />
        """)

      assert html =~ "unassigned"
      refute html =~ "Jamie K"
    end

    test "tolerates an unloaded assigned_to association" do
      assigns = %{task: child(%{assigned_to: %Ecto.Association.NotLoaded{}})}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} />
        """)

      assert html =~ "unassigned"
    end
  end

  describe "goal_child_row/1 — click event" do
    test "emits the configured phx-click event with phx-value-id" do
      assigns = %{task: child()}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} on_click="open_child" />
        """)

      assert html =~ ~s(phx-click="open_child")
      assert html =~ ~s(phx-value-id="1234")
      assert html =~ "cursor: pointer;"
    end

    test "omits phx-click + pointer cursor when on_click is nil" do
      assigns = %{task: child()}

      html =
        rendered_to_string(~H"""
        <GoalChildRow.goal_child_row task={@task} />
        """)

      refute html =~ ~s(phx-click=")
      refute html =~ "cursor: pointer;"
    end
  end
end
