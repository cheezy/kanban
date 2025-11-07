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
    attrs =
      Enum.into(attrs, %{
        title: "Test Task #{System.unique_integer([:positive])}"
      })

    {:ok, task} = Tasks.create_task(column, attrs)

    task
  end
end
