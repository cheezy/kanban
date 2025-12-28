defmodule Kanban.TasksFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Tasks` context.
  """

  alias Kanban.Tasks

  @doc """
  Generate a task for a given column.
  """
  def task_fixture(column, attrs \\ %{}) do
    # If dependencies are provided with placeholder identifiers, create actual dependency tasks
    dependencies = Map.get(attrs, :dependencies, Map.get(attrs, "dependencies"))

    attrs =
      if is_list(dependencies) && dependencies != [] do
        # Create actual dependency tasks for each placeholder
        dep_tasks =
          Enum.map(dependencies, fn _placeholder ->
            {:ok, dep} =
              Tasks.create_task(column, %{
                "title" => "Dependency Task #{System.unique_integer([:positive])}"
              })

            dep.identifier
          end)

        Map.put(attrs, :dependencies, dep_tasks)
      else
        attrs
      end

    attrs =
      Enum.into(attrs, %{
        title: "Test Task #{System.unique_integer([:positive])}",
        type: :work,
        priority: :medium
      })

    {:ok, task} = Tasks.create_task(column, attrs)

    task
  end
end
