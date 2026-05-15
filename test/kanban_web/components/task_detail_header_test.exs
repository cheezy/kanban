defmodule KanbanWeb.TaskDetailHeaderTest do
  @moduledoc """
  Contract tests for `KanbanWeb.TaskDetailHeader.detail_header/1` — the
  anchor band shared by the task-detail pane and full-screen variants.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskDetailHeader

  defp task(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "W199",
        title: "Migrate detail surface to the new design",
        type: :work,
        status: :ready,
        priority: :high,
        complexity: :large,
        ai_generated?: false,
        author: nil
      },
      overrides
    )
  end

  describe "detail_header/1 — base render" do
    test "renders identifier and title" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "W199"
      assert html =~ "Migrate detail surface to the new design"
    end

    test "outermost element carries the data-detail-header marker" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "data-detail-header"
    end

    test "title is rendered inside an <h1>" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ ~r/<h1[^>]*>\s*Migrate detail surface to the new design\s*<\/h1>/
    end
  end

  describe "detail_header/1 — type accent" do
    test "renders the work icon by default" do
      assigns = %{task: task(%{type: :work})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "hero-document-text"
      assert html =~ "var(--st-ready)"
    end

    test "renders the defect icon for :defect" do
      assigns = %{task: task(%{type: :defect})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "hero-bug-ant"
      assert html =~ "var(--st-blocked)"
    end

    test "renders the goal icon for :goal" do
      assigns = %{task: task(%{type: :goal})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "hero-flag"
      assert html =~ "var(--stride-violet)"
    end
  end

  describe "detail_header/1 — status pill" do
    for {status, label, soft, ink} <- [
          {:open, "Open", "var(--st-backlog-soft)", "var(--st-backlog)"},
          {:ready, "Ready", "var(--st-ready-soft)", "var(--st-ready)"},
          {:in_progress, "Doing", "var(--st-doing-soft)", "var(--st-doing)"},
          {:review, "Review", "var(--st-review-soft)", "var(--st-review)"},
          {:completed, "Done", "var(--st-done-soft)", "var(--st-done)"}
        ] do
      test "status=#{status} renders #{label} with the matching token pair" do
        assigns = %{task: task(%{status: unquote(status)})}

        html =
          rendered_to_string(~H"""
          <TaskDetailHeader.detail_header task={@task} />
          """)

        assert html =~ unquote(label)
        assert html =~ "background: #{unquote(soft)};"
        assert html =~ "color: #{unquote(ink)};"
      end
    end
  end

  describe "detail_header/1 — AI pill" do
    test "renders the AI pill only when ai_generated? is true" do
      assigns = %{task: task(%{ai_generated?: true})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ ~r/>\s*AI\s*</
      assert html =~ "var(--stride-violet-soft)"
    end

    test "omits the AI pill when ai_generated? is false" do
      assigns = %{task: task(%{ai_generated?: false})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      refute html =~ "var(--stride-violet-soft)"
    end

    test "also accepts the unquestioned :ai_generated key from struct callers" do
      assigns = %{task: task() |> Map.delete(:ai_generated?) |> Map.put(:ai_generated, true)}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ ~r/>\s*AI\s*</
    end
  end

  describe "detail_header/1 — priority dot + meta" do
    test "renders the priority dot color matching the task priority" do
      assigns = %{task: task(%{priority: :critical})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "var(--pri-critical)"
    end

    test "renders 'Priority · Complexity' meta label when both are present" do
      assigns = %{task: task(%{priority: :high, complexity: :large})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      assert html =~ "High · Large"
    end

    test "omits the priority dot when priority is nil" do
      assigns = %{task: task(%{priority: nil})}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      refute html =~ "var(--pri-"
    end
  end

  describe "detail_header/1 — owner avatar" do
    test "renders the author avatar when :author is present" do
      assigns = %{
        task: task(%{author: %{kind: :human, name: "Jamie K", palette: "human-green"}})
      }

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      # Avatar component renders an oklch palette swatch.
      assert html =~ "oklch(60% 0.10 155)"
    end

    test "omits the avatar when :author is nil" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      refute html =~ "oklch(60% 0.10 155)"
    end
  end

  describe "detail_header/1 — close affordance" do
    test "renders the Esc close button wired to the configured event" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} on_close="close_detail" />
        """)

      assert html =~ ~s(phx-click="close_detail")
      assert html =~ ~s(aria-label="Close task detail")
      assert html =~ ~r/>\s*Esc\s*</
    end

    test "omits the close button when on_close is nil" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} />
        """)

      refute html =~ ~s(aria-label="Close task detail")
    end
  end

  describe "detail_header/1 — variant padding" do
    test "pane variant uses 14px 22px 12px padding" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} variant={:pane} />
        """)

      assert html =~ "padding: 14px 22px 12px;"
    end

    test "full variant uses the wider 20px 32px 16px padding" do
      assigns = %{task: task()}

      html =
        rendered_to_string(~H"""
        <TaskDetailHeader.detail_header task={@task} variant={:full} />
        """)

      assert html =~ "padding: 20px 32px 16px;"
    end
  end
end
