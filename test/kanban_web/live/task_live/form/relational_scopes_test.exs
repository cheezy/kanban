defmodule KanbanWeb.TaskLive.Form.RelationalScopesTest do
  @moduledoc """
  Unit tests for the task form's relational board-scope checks, extracted
  from `KanbanWeb.TaskLive.FormComponent` in W2234. The form-level save tests
  in form_component_test.exs still exercise them end to end.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias KanbanWeb.TaskLive.Form.RelationalScopes

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    other_user = user_fixture()
    other_board = board_fixture(other_user)
    other_column = column_fixture(other_board)

    %{
      user: user,
      board: board,
      column: column,
      goal: task_fixture(column, %{type: :goal}),
      other_user: other_user,
      other_column: other_column,
      other_goal: task_fixture(other_column, %{type: :goal})
    }
  end

  test "blank and absent fields pass", ctx do
    assert RelationalScopes.validate(%{}, ctx.board) == :ok

    assert RelationalScopes.validate(
             %{"column_id" => "", "parent_id" => "", "assigned_to_id" => ""},
             ctx.board
           ) == :ok
  end

  test "fields on the current board pass", ctx do
    params = %{
      "column_id" => to_string(ctx.column.id),
      "parent_id" => to_string(ctx.goal.id),
      "assigned_to_id" => to_string(ctx.user.id)
    }

    assert RelationalScopes.validate(params, ctx.board) == :ok
  end

  test "a column on another board is rejected", ctx do
    assert {:error, :column_id, _} =
             RelationalScopes.validate(
               %{"column_id" => to_string(ctx.other_column.id)},
               ctx.board
             )
  end

  test "a parent goal on another board, or a malformed one, is rejected", ctx do
    assert {:error, :parent_id, _} =
             RelationalScopes.validate(%{"parent_id" => to_string(ctx.other_goal.id)}, ctx.board)

    assert {:error, :parent_id, _} = RelationalScopes.validate(%{"parent_id" => "x"}, ctx.board)
  end

  test "an assignee without access to the board is rejected", ctx do
    assert {:error, :assigned_to_id, _} =
             RelationalScopes.validate(
               %{"assigned_to_id" => to_string(ctx.other_user.id)},
               ctx.board
             )
  end
end
