defmodule KanbanWeb.TaskLive.Components.ChildTasksSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.ChildTasksSection

  defp render_section(children) do
    render_component(&ChildTasksSection.child_tasks_section/1, children: children)
  end

  defp child(attrs) do
    Enum.into(attrs, %{
      identifier: "W1",
      title: "Default title",
      type: :work,
      column: %{name: "Doing"}
    })
  end

  describe "child_tasks_section/1" do
    test "renders the Child Tasks heading" do
      assert render_section([]) =~ "Child Tasks"
    end

    test "renders all column headers" do
      html = render_section([])

      assert html =~ "ID"
      assert html =~ "Title"
      assert html =~ "Type"
      assert html =~ "Column"
    end

    test "renders an empty tbody when there are no children" do
      html = render_section([])

      assert html =~ "<tbody"
      refute html =~ "<tr class=\"hover:bg-base-200\""
    end

    test "renders identifier, title, and column name for a child" do
      html =
        render_section([
          child(identifier: "W42", title: "Refactor module", column: %{name: "Review"})
        ])

      assert html =~ "W42"
      assert html =~ "Refactor module"
      assert html =~ "Review"
    end

    test "renders work-type badge with Work label and blue styling" do
      html = render_section([child(type: :work)])

      assert html =~ "Work"
      assert html =~ "bg-blue-100"
      assert html =~ "text-blue-800"
    end

    test "renders defect-type badge with Defect label and red styling" do
      html = render_section([child(type: :defect)])

      assert html =~ "Defect"
      assert html =~ "bg-red-100"
      assert html =~ "text-red-800"
    end

    test "renders goal-type badge with Goal label and yellow styling" do
      html = render_section([child(type: :goal)])

      assert html =~ "Goal"
      assert html =~ "bg-yellow-100"
      assert html =~ "text-yellow-800"
    end

    test "renders one table row per child" do
      html =
        render_section([
          child(identifier: "W1", title: "First"),
          child(identifier: "W2", title: "Second"),
          child(identifier: "W3", title: "Third")
        ])

      assert html =~ "W1"
      assert html =~ "W2"
      assert html =~ "W3"
      assert html =~ "First"
      assert html =~ "Second"
      assert html =~ "Third"
    end

    test "renders mixed-type children with their respective badges" do
      html =
        render_section([
          child(identifier: "W1", type: :work),
          child(identifier: "D1", type: :defect),
          child(identifier: "G1", type: :goal)
        ])

      assert html =~ "Work"
      assert html =~ "Defect"
      assert html =~ "Goal"
      assert html =~ "W1"
      assert html =~ "D1"
      assert html =~ "G1"
    end
  end
end
