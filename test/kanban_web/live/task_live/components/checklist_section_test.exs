defmodule KanbanWeb.TaskLive.Components.ChecklistSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.ChecklistSection

  defp render_checklist(testing_strategy) do
    render_component(&ChecklistSection.checklist_section/1, testing_strategy: testing_strategy)
  end

  describe "checklist_section/1" do
    test "renders the Testing Strategy heading" do
      assert render_checklist(%{"unit_tests" => ["one"]}) =~ "Testing Strategy"
    end

    test "renders unit tests when given a non-empty list" do
      html = render_checklist(%{"unit_tests" => ["Test A", "Test B"]})

      assert html =~ "Unit Tests"
      assert html =~ "Test A"
      assert html =~ "Test B"
    end

    test "renders integration tests when given a non-empty list" do
      html = render_checklist(%{"integration_tests" => ["End-to-end auth"]})

      assert html =~ "Integration Tests"
      assert html =~ "End-to-end auth"
    end

    test "renders manual tests when given a non-empty list" do
      html = render_checklist(%{"manual_tests" => ["Visual QA in dev"]})

      assert html =~ "Manual Tests"
      assert html =~ "Visual QA in dev"
    end

    test "renders all three sections when each has items" do
      html =
        render_checklist(%{
          "unit_tests" => ["u1"],
          "integration_tests" => ["i1"],
          "manual_tests" => ["m1"]
        })

      assert html =~ "Unit Tests"
      assert html =~ "Integration Tests"
      assert html =~ "Manual Tests"
      assert html =~ "u1"
      assert html =~ "i1"
      assert html =~ "m1"
    end

    test "wraps a single binary as a one-item list" do
      html = render_checklist(%{"unit_tests" => "Single test"})

      assert html =~ "Unit Tests"
      assert html =~ "Single test"
    end

    test "omits a section when its value is an empty list" do
      html = render_checklist(%{"unit_tests" => [], "integration_tests" => ["keep"]})

      refute html =~ "Unit Tests"
      assert html =~ "Integration Tests"
      assert html =~ "keep"
    end

    test "omits a section when its value is an empty string" do
      html = render_checklist(%{"unit_tests" => "", "manual_tests" => ["keep"]})

      refute html =~ "Unit Tests"
      assert html =~ "Manual Tests"
    end

    test "omits a section when its value is whitespace only" do
      html = render_checklist(%{"unit_tests" => "   \n\t  ", "manual_tests" => ["keep"]})

      refute html =~ "Unit Tests"
      assert html =~ "Manual Tests"
    end

    test "omits a section when its value is nil" do
      html = render_checklist(%{"unit_tests" => nil, "manual_tests" => ["keep"]})

      refute html =~ "Unit Tests"
      assert html =~ "Manual Tests"
    end

    test "omits a section when the key is absent" do
      html = render_checklist(%{"unit_tests" => ["u1"]})

      assert html =~ "Unit Tests"
      refute html =~ "Integration Tests"
      refute html =~ "Manual Tests"
    end

    test "renders the container even when no sections have items" do
      html = render_checklist(%{})

      assert html =~ "Testing Strategy"
      refute html =~ "Unit Tests"
      refute html =~ "Integration Tests"
      refute html =~ "Manual Tests"
    end

    test "ignores unknown keys without crashing" do
      html = render_checklist(%{"unknown_key" => ["x"], "unit_tests" => ["u1"]})

      assert html =~ "u1"
      refute html =~ "unknown_key"
    end
  end
end
