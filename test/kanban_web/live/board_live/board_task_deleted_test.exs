defmodule KanbanWeb.BoardLive.BoardTaskDeletedTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.AttachmentsComponent

  # A task deleted elsewhere (another session, an agent through the API)
  # cascades its attachments away without an :attachment_changed broadcast,
  # so an open view of it must close rather than keep listing files that are
  # gone.

  setup :register_and_log_in_user

  setup %{user: owner} do
    board = board_fixture(owner)
    column = column_fixture(board)
    task = task_fixture(column)
    attachment_fixture(task, %{uploaded_by: owner, filename: "doomed.txt"})
    %{board: board, column: column, task: task}
  end

  defp open_task_view(conn, board, task) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "view_task", %{"id" => to_string(task.id)})
    :timer.sleep(200)
    view
  end

  defp section(host, task), do: "#" <> AttachmentsComponent.dom_id(host, task.id)

  defp delete_elsewhere(task) do
    {:ok, _deleted} = task.id |> Tasks.get_task!() |> Tasks.delete_task()
    :timer.sleep(100)
  end

  test "an open task view closes and says so when the task is deleted elsewhere",
       %{conn: conn, board: board, task: task} do
    view = open_task_view(conn, board, task)
    assert render(view) =~ "doomed.txt"

    delete_elsewhere(task)

    html = render(view)
    refute has_element?(view, "#task-modal-wrapper-#{task.id}")
    refute has_element?(view, section(:view, task))
    refute html =~ "doomed.txt"
    assert html =~ "This task was deleted."
  end

  test "an open edit form returns to the board and says so when the task is deleted elsewhere",
       %{conn: conn, board: board, task: task} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
    assert has_element?(view, section(:form, task))

    delete_elsewhere(task)

    # The patch is pushed from the view's handle_info for the deletion
    # broadcast. assert_patch's default 100 ms window missed it under
    # full-suite load (W2516 after_doing), so wait as long as a slow run needs.
    assert_patch(view, ~p"/boards/#{board}", 2_000)
    refute has_element?(view, section(:form, task))
    assert render(view) =~ "This task was deleted."
  end

  test "patching to another board leaves the first board's topic",
       %{conn: conn, user: owner, board: board} do
    other = board_fixture(owner)
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    assert "board:#{board.id}" in Registry.keys(Kanban.PubSub, view.pid)

    render_patch(view, ~p"/boards/#{other}")

    topics = Registry.keys(Kanban.PubSub, view.pid)
    assert "board:#{other.id}" in topics
    refute "board:#{board.id}" in topics
  end

  test "deleting another task leaves the open task view as it is",
       %{conn: conn, board: board, column: column, task: task} do
    other = task_fixture(column)
    view = open_task_view(conn, board, task)

    delete_elsewhere(other)

    assert has_element?(view, "#task-modal-wrapper-#{task.id}")
    assert render(view) =~ "doomed.txt"
    refute render(view) =~ "This task was deleted."
  end
end
