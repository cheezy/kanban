defmodule KanbanWeb.TaskLive.ViewComponentTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.AccountsFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory

  describe "ViewComponent" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      %{user: user, board: board, column: column, task: task}
    end

    test "renders task details", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ task.title
      assert result =~ task.identifier
    end

    test "displays task description when present", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{description: "This is a test description"})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Description"
      assert result =~ "This is a test description"
    end

    test "does not display description section when nil", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{description: nil})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      refute result =~ "Description"
    end

    test "displays column name", %{task: task, column: column} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Status"
      assert result =~ column.name
    end

    test "displays Work type with blue badge", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{type: :work})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Work"
      assert result =~ "bg-blue-100 text-blue-800"
    end

    test "displays Defect type with red badge", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{type: :defect})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Defect"
      assert result =~ "bg-red-100 text-red-800"
    end

    test "displays Low priority with blue color", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :low})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Low"
      assert result =~ "text-blue-600"
    end

    test "displays Medium priority with yellow color", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :medium})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Medium"
      assert result =~ "text-yellow-600"
    end

    test "displays High priority with orange color", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :high})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "High"
      assert result =~ "text-orange-600"
    end

    test "displays Critical priority with red color", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :critical})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Critical"
      assert result =~ "text-red-600"
    end

    test "displays assigned user when present", %{board: board} do
      user = user_fixture(%{name: "John Doe"})
      column = column_fixture(board)
      task = task_fixture(column, %{assigned_to_id: user.id})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Assigned To"
      assert result =~ "John Doe"
    end

    test "displays 'Unassigned' when no user assigned", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Assigned To"
      assert result =~ "Unassigned"
    end

    test "displays created date with formatted datetime", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Created"
      assert result =~ ~r/\w+ \d{1,2}, \d{4} at \d{1,2}:\d{2} (AM|PM)/
    end

    test "displays creation history automatically created with task", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "History"
      assert result =~ "Created"
    end

    test "displays creation history with green icon", %{task: task} do
      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :creation,
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Created"
      assert result =~ "hero-plus-circle"
      assert result =~ "text-green-600"
    end

    test "displays move history with from and to columns", %{task: task} do
      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :move,
        from_column: "To Do",
        to_column: "In Progress",
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Moved"
      assert result =~ "from"
      assert result =~ "To Do"
      assert result =~ "to"
      assert result =~ "In Progress"
      assert result =~ "hero-arrow-right-circle"
      assert result =~ "text-blue-600"
    end

    test "displays multiple history entries", %{task: task} do
      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :creation,
        inserted_at: ~U[2024-01-15 10:00:00Z]
      })
      |> Repo.insert!()

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :move,
        from_column: "To Do",
        to_column: "In Progress",
        inserted_at: ~U[2024-01-15 11:00:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Created"
      assert result =~ "Moved"
    end

    test "displays 'No comments yet' when task has no comments", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "Comments"
      assert result =~ "No comments yet"
    end

    test "displays comment content", %{task: task} do
      %TaskComment{}
      |> TaskComment.changeset(%{
        task_id: task.id,
        content: "This is a test comment",
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "This is a test comment"
      assert result =~ "hero-chat-bubble-left"
    end

    test "displays multiple comments", %{task: task} do
      %TaskComment{}
      |> TaskComment.changeset(%{
        task_id: task.id,
        content: "First comment",
        inserted_at: ~U[2024-01-15 10:00:00Z]
      })
      |> Repo.insert!()

      %TaskComment{}
      |> TaskComment.changeset(%{
        task_id: task.id,
        content: "Second comment",
        inserted_at: ~U[2024-01-15 11:00:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ "First comment"
      assert result =~ "Second comment"
    end

    test "displays comment timestamp with formatted datetime", %{task: task} do
      %TaskComment{}
      |> TaskComment.changeset(%{
        task_id: task.id,
        content: "Test comment",
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ ~r/\w+ \d{1,2}, \d{4} at \d{1,2}:\d{2} (AM|PM)/
    end

    test "displays history timestamp with formatted datetime", %{task: task} do
      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :creation,
        inserted_at: ~U[2024-01-15 14:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id
        )

      assert result =~ ~r/\w+ \d{1,2}, \d{4} at \d{1,2}:\d{2} (AM|PM)/
    end

    test "displays Edit link when can_modify is true", %{task: task, board: board} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          board_id: board.id,
          can_modify: true
        )

      assert result =~ "Edit"
      assert result =~ ~p"/boards/#{board}/tasks/#{task}/edit"
    end

    test "does not display Edit link when can_modify is false", %{task: task, board: board} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          board_id: board.id,
          can_modify: false
        )

      refute result =~ "Edit"
    end

    test "does not display Edit link when board_id is not provided", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          can_modify: true
        )

      refute result =~ "Edit"
    end
  end
end
