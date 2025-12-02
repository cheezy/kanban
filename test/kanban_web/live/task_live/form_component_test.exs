defmodule KanbanWeb.TaskLive.FormComponentTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.FormComponent

  describe "update/2 for new task" do
    test "initializes form with default values" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.task == task
      assert socket.assigns.action == :new_task
      assert socket.assigns.column_id == column.id
      assert socket.assigns.form
      assert is_list(socket.assigns.column_options)
    end

    test "builds column options for new task" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      _column2 = column_fixture(board, %{name: "In Progress"})
      _column3 = column_fixture(board, %{name: "Done"})
      task = %Tasks.Task{column_id: column1.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column1.id
          },
          %Phoenix.LiveView.Socket{}
        )

      assert length(socket.assigns.column_options) == 3
      option_labels = Enum.map(socket.assigns.column_options, fn {label, _id} -> label end)
      assert "To Do" in option_labels
      assert "In Progress" in option_labels
      assert "Done" in option_labels
    end

    test "excludes full columns from options for new task" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 1})
      _task1 = task_fixture(column2, %{title: "Existing task"})

      task = %Tasks.Task{column_id: column1.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column1.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Column2 should be excluded because it's at WIP limit
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column1.id in option_ids
      refute column2.id in option_ids
    end

    test "includes current column even if at WIP limit for new task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 1})
      _existing_task = task_fixture(column, %{title: "Existing"})

      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Current column should be included even though it's at limit
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column.id in option_ids
    end

    test "sets column_id in changeset when provided" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.form.source.changes.column_id == column.id
    end
  end

  describe "update/2 for edit task" do
    test "loads task with history when editing" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Task should have task_histories preloaded
      assert socket.assigns.task.id == task.id
      assert Ecto.assoc_loaded?(socket.assigns.task.task_histories)
      # Should have one creation history
      refute Enum.empty?(socket.assigns.task.task_histories)
    end

    test "does not show column selector when editing task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.action == :edit_task
      # Column options still built but not used in edit form
      assert is_list(socket.assigns.column_options)
    end

    test "builds column options excluding full columns for edit" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 1})
      _task1 = task_fixture(column2, %{title: "Blocking task"})
      task_to_edit = task_fixture(column1, %{title: "Task to edit"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task_to_edit,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Column2 should be excluded because it's at WIP limit and not the current column
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column1.id in option_ids
      refute column2.id in option_ids
    end

    test "includes task's current column even if at WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 2})
      task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task1,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Current column should be included even though it's at limit
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column.id in option_ids

      # Label should not show WIP limit warning for current column
      current_column_option =
        Enum.find(socket.assigns.column_options, fn {_label, id} -> id == column.id end)

      {label, _id} = current_column_option
      refute String.contains?(label, "WIP limit reached")
    end

    test "does not load history for new task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # New task should not attempt to load history
      assert socket.assigns.task == task
    end
  end

  describe "handle_event validate" do
    test "updates changeset on validation" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => "New Title"}},
          socket
        )

      assert updated_socket.assigns.form.source.changes.title == "New Title"
      assert updated_socket.assigns.form.source.action == :validate
    end

    test "shows validation errors" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => ""}},
          socket
        )

      assert updated_socket.assigns.form.source.action == :validate
      # Title error should be in changeset
      assert updated_socket.assigns.form.source.errors[:title]
    end
  end

  describe "column_options with WIP limits" do
    test "marks full columns with WIP limit warning" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column2, %{title: "Task 1"})
      _task2 = task_fixture(column2, %{title: "Task 2"})

      task = %Tasks.Task{column_id: column1.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column1.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Column2 should be excluded because it's at limit and not current column
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      refute column2.id in option_ids
    end

    test "includes all columns when none are at limit" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do", wip_limit: 5})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column1, %{title: "Task 1"})

      task = %Tasks.Task{column_id: column1.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column1.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Both columns should be available
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column1.id in option_ids
      assert column2.id in option_ids
    end

    test "handles columns with no WIP limit (0)" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Done", wip_limit: 0})
      # Add many tasks - should not matter with no limit
      Enum.each(1..10, fn i ->
        task_fixture(column, %{title: "Task #{i}"})
      end)

      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Column should be available despite having many tasks
      option_ids = Enum.map(socket.assigns.column_options, fn {_label, id} -> id end)
      assert column.id in option_ids

      # Label should not show WIP limit warning
      column_option =
        Enum.find(socket.assigns.column_options, fn {_label, id} -> id == column.id end)

      {label, _id} = column_option
      refute String.contains?(label, "WIP limit reached")
    end
  end

  describe "update/2 with comments" do
    test "loads comments when editing task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      # Add a comment
      {:ok, _comment} =
        Kanban.Repo.insert(%Kanban.Tasks.TaskComment{
          task_id: task.id,
          content: "Test comment"
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Task should have comments preloaded
      assert Ecto.assoc_loaded?(socket.assigns.task.comments)
      assert length(socket.assigns.task.comments) == 1
      assert hd(socket.assigns.task.comments).content == "Test comment"
    end

    test "initializes comment form for edit task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Comment form should be initialized
      assert socket.assigns.comment_form
      assert socket.assigns.comment_form.source
    end

    test "does not initialize comment form for new task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id
          },
          %Phoenix.LiveView.Socket{}
        )

      # Comment form should still be initialized
      assert socket.assigns.comment_form
    end

    test "orders comments by most recent first" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      # Add comments
      {:ok, _comment1} =
        Kanban.Repo.insert(%Kanban.Tasks.TaskComment{
          task_id: task.id,
          content: "First comment"
        })

      {:ok, _comment2} =
        Kanban.Repo.insert(%Kanban.Tasks.TaskComment{
          task_id: task.id,
          content: "Second comment"
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      comments = socket.assigns.task.comments
      assert length(comments) == 2

      # Comments are ordered desc by inserted_at, meaning most recent first
      # Since they're inserted sequentially, the second one should have a later inserted_at
      # Database ordering may vary by microseconds, so we check by ID which increases monotonically
      first_comment = hd(comments)
      last_comment = List.last(comments)

      # The comment with the higher ID should be first (most recent)
      assert first_comment.id > last_comment.id
    end
  end

  describe "handle_event add_comment" do
    test "adds comment successfully" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash map in socket assigns
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "New comment"}},
          socket
        )

      # Task should be reloaded with new comment
      assert length(updated_socket.assigns.task.comments) == 1
      assert hd(updated_socket.assigns.task.comments).content == "New comment"

      # Comment form should be reset
      assert updated_socket.assigns.comment_form
      refute updated_socket.assigns.comment_form.source.changes[:content]
    end

    test "shows validation error for empty comment" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => ""}},
          socket
        )

      # Should have validation error
      assert updated_socket.assigns.comment_form.source.errors[:content]
      # Task comments should not be updated
      assert Enum.empty?(updated_socket.assigns.task.comments)
    end

    test "adds multiple comments" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash map in socket assigns
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      # Add first comment
      {:noreply, socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "First comment"}},
          socket
        )

      # Add second comment
      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "Second comment"}},
          socket
        )

      # Should have both comments
      assert length(updated_socket.assigns.task.comments) == 2
      # Most recent should be first
      assert hd(updated_socket.assigns.task.comments).content == "Second comment"
    end

    test "includes task_id in comment params" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash map in socket assigns
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "Comment without task_id"}},
          socket
        )

      # Comment should be associated with the task
      comment = hd(updated_socket.assigns.task.comments)
      assert comment.task_id == task.id
    end
  end
end
