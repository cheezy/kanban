defmodule KanbanWeb.TaskLive.Components.ActualVsEstimatedSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.ActualVsEstimatedSection

  defp render_section(task_attrs) do
    task =
      Enum.into(task_attrs, %{
        actual_complexity: nil,
        complexity: nil,
        actual_files_changed: nil,
        estimated_files: nil,
        time_spent_minutes: nil
      })

    render_component(&ActualVsEstimatedSection.actual_vs_estimated_section/1, task: task)
  end

  describe "actual_vs_estimated_section/1" do
    test "renders the Actual vs Estimated heading" do
      assert render_section(%{}) =~ "Actual vs Estimated"
    end

    test "renders actual complexity label and value" do
      html = render_section(%{actual_complexity: :small})

      assert html =~ "Actual Complexity"
      assert html =~ "Small"
    end

    test "renders each complexity atom with its translated label" do
      assert render_section(%{actual_complexity: :small}) =~ "Small"
      assert render_section(%{actual_complexity: :medium}) =~ "Medium"
      assert render_section(%{actual_complexity: :large}) =~ "Large"
    end

    test "includes the estimated complexity in parens when complexity is set" do
      html = render_section(%{actual_complexity: :large, complexity: :medium})

      assert html =~ "Large"
      assert html =~ "(Est"
      assert html =~ "Medium"
    end

    test "omits the estimated parens when complexity is nil" do
      html = render_section(%{actual_complexity: :large, complexity: nil})

      assert html =~ "Large"
      refute html =~ "(Est"
    end

    test "omits the Actual Complexity section when actual_complexity is nil" do
      html = render_section(%{actual_complexity: nil, complexity: :medium})

      refute html =~ "Actual Complexity"
    end

    test "renders Actual Files Changed when set" do
      html = render_section(%{actual_files_changed: "lib/foo.ex, lib/bar.ex"})

      assert html =~ "Actual Files Changed"
      assert html =~ "lib/foo.ex, lib/bar.ex"
    end

    test "includes the estimated files in parens when estimated_files is set" do
      html = render_section(%{actual_files_changed: "lib/foo.ex", estimated_files: "1-2"})

      assert html =~ "lib/foo.ex"
      assert html =~ "1-2"
      assert html =~ "(Est"
    end

    test "omits the estimated-files parens when estimated_files is nil" do
      html = render_section(%{actual_files_changed: "lib/foo.ex", estimated_files: nil})

      assert html =~ "lib/foo.ex"
      refute html =~ "(Est"
    end

    test "omits the Actual Files Changed section when not set" do
      html = render_section(%{actual_files_changed: nil, estimated_files: "1-2"})

      refute html =~ "Actual Files Changed"
    end

    test "renders Time Spent in minutes when set" do
      html = render_section(%{time_spent_minutes: 45})

      assert html =~ "Time Spent"
      assert html =~ "45"
      assert html =~ "minutes"
    end

    test "renders 0 minutes when time_spent_minutes is 0" do
      html = render_section(%{time_spent_minutes: 0})

      assert html =~ "Time Spent"
      assert html =~ "0"
    end

    test "omits the Time Spent section when time_spent_minutes is nil" do
      html = render_section(%{time_spent_minutes: nil})

      refute html =~ "Time Spent"
    end

    test "renders all three sections when every value is present" do
      html =
        render_section(%{
          actual_complexity: :medium,
          complexity: :small,
          actual_files_changed: "lib/foo.ex",
          estimated_files: "3-5",
          time_spent_minutes: 60
        })

      assert html =~ "Actual Complexity"
      assert html =~ "Actual Files Changed"
      assert html =~ "Time Spent"
      assert html =~ "Medium"
      assert html =~ "lib/foo.ex"
      assert html =~ "60"
    end

    test "renders only the heading when no actual values are present" do
      html = render_section(%{})

      assert html =~ "Actual vs Estimated"
      refute html =~ "Actual Complexity"
      refute html =~ "Actual Files Changed"
      refute html =~ "Time Spent"
    end
  end
end
