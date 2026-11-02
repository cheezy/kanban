defmodule KanbanWeb.BoardLive.BoardStateTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.BoardLive.BoardState

  describe "task_form_id/2" do
    test "New task and New goal get different ids, so neither inherits the other's staged files" do
      assert BoardState.task_form_id(:new_task, nil) == "new-task"
      assert BoardState.task_form_id(:new_goal, false) == "new-goal"
      refute BoardState.task_form_id(:new_task, nil) == BoardState.task_form_id(:new_goal, nil)
    end

    test "an edit form is keyed by its task" do
      assert BoardState.task_form_id(:edit_task, %{id: 42}) == "edit-42"
    end
  end
end
