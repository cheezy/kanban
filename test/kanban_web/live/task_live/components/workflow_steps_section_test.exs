defmodule KanbanWeb.TaskLive.Components.WorkflowStepsSectionTest do
  @moduledoc """
  Unit tests for the D242 duration rendering rule.

  `after_doing` and `before_review` carry a permanent `0` because each fires
  around the very request whose body already contains its own result — so the
  figure does not exist when the payload is serialised. The panel must not
  render that placeholder as a measurement: `"0 ms"` is indistinguishable from
  a genuine near-instant run, which is the display defect D242 recorded.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.WorkflowStepsSection

  defp render_steps(steps) do
    render_component(&WorkflowStepsSection.workflow_steps_section/1, steps: steps)
  end

  describe "duration rendering — structurally unknowable figures" do
    test "after_doing with a zero duration renders an em dash, not 0 ms" do
      html = render_steps([%{"name" => "after_doing", "dispatched" => true, "duration_ms" => 0}])

      assert html =~ "—"
      refute html =~ "0 ms"
    end

    test "before_review with a zero duration renders an em dash, not 0 ms" do
      html =
        render_steps([%{"name" => "before_review", "dispatched" => true, "duration_ms" => 0}])

      assert html =~ "—"
      refute html =~ "0 ms"
    end

    test "a non-zero figure on those steps still renders — the rule is forward-compatible" do
      html =
        render_steps([%{"name" => "after_doing", "dispatched" => true, "duration_ms" => 150_279}])

      assert html =~ "150279 ms"
      refute html =~ "—"
    end
  end

  describe "duration rendering — genuinely measured figures" do
    test "a measured step renders its duration" do
      html =
        render_steps([%{"name" => "explorer", "dispatched" => true, "duration_ms" => 184_255}])

      assert html =~ "184255 ms"
    end

    test "a zero on a step that CAN be measured is left alone" do
      html = render_steps([%{"name" => "explorer", "dispatched" => true, "duration_ms" => 0}])

      assert html =~ "0 ms"
      refute html =~ "—"
    end

    test "a step with no duration key renders no duration at all" do
      html =
        render_steps([
          %{"name" => "planner", "dispatched" => false, "reason" => "Decision matrix"}
        ])

      refute html =~ ~r/\d+ ms/
      refute html =~ "—"
    end

    test "a non-integer duration renders no duration rather than raising" do
      html =
        render_steps([%{"name" => "reviewer", "dispatched" => true, "duration_ms" => "fast"}])

      refute html =~ "fast"
      refute html =~ ~r/\d+ ms/
      refute html =~ "—"
    end
  end
end
