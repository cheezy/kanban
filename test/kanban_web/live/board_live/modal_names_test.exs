defmodule KanbanWeb.BoardLive.ModalNamesTest do
  @moduledoc """
  Every dialog the board page opens carries an accessible name, so a screen
  reader announces what opened rather than an unnamed "dialog".
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  setup [:register_and_log_in_user]

  defp dialog_name(html) do
    [dialog] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([role="dialog"]))
      |> Enum.to_list()

    assert LazyHTML.attribute(dialog, "aria-labelledby") == []
    assert [name] = LazyHTML.attribute(dialog, "aria-label")
    name
  end

  test "board, column and task dialogs are named", %{conn: conn, user: user} do
    board = board_fixture(user)
    column = column_fixture(board)
    task = task_fixture(column)

    for {path, name} <- [
          {~p"/boards/#{board}/settings", "Board settings"},
          {~p"/boards/#{board}/members", "Manage members"},
          {~p"/boards/#{board}/integrations", "Integrations"},
          {~p"/boards/#{board}/columns/new", "New column"},
          {~p"/boards/#{board}/columns/#{column}/edit", "Edit column"},
          {~p"/boards/#{board}/columns/#{column}/tasks/new", "New task"},
          {~p"/boards/#{board}/tasks/#{task}/edit", "Edit task"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert dialog_name(html) == name, "wrong dialog name on #{path}"
    end
  end

  test "the API tokens dialog is named", %{conn: conn, user: user} do
    board = ai_optimized_board_fixture(user)

    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/api_tokens")

    assert dialog_name(html) == "API tokens"
  end
end
