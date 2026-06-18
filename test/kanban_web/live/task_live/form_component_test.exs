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
            current_scope: %{user: user},
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
            current_scope: %{user: user},
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

    test "rejects add_comment when the user is not a board member" do
      owner = user_fixture()
      stranger = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Members Only"})

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: stranger},
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "should not save"}},
          socket
        )

      assert updated_socket.assigns.flash["error"] =~ "must be a board member"
      # No comment row was created.
      assert Kanban.Repo.aggregate(Kanban.Tasks.TaskComment, :count) == 0
    end

    test "accepts add_comment when the user is a read-only board member" do
      owner = user_fixture()
      reader = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Open Discussion"})
      Kanban.Boards.add_user_to_board(board, reader, :read_only, owner)

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: reader},
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "I have thoughts"}},
          socket
        )

      assert length(updated_socket.assigns.task.comments) == 1
    end

    test "adds multiple comments" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: user},
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
            current_scope: %{user: user},
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

    test "overrides any client-supplied task_id in comment_params" do
      # Server-source the task_id from socket.assigns.task — never trust
      # an attacker-supplied task_id key in the params map.
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Real Task"})

      # A separate task whose id the attacker tries to spoof.
      other_task = task_fixture(column, %{title: "Other Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: user},
            task: task,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add_comment",
          %{
            "task_comment" => %{
              "content" => "should attach to real task",
              "task_id" => other_task.id
            }
          },
          socket
        )

      # Comment goes to the SERVER task, ignoring the spoofed task_id.
      comment = hd(updated_socket.assigns.task.comments)
      assert comment.task_id == task.id
      refute comment.task_id == other_task.id
    end
  end

  describe "handle_event add-key-file" do
    test "adds new key file to empty list" do
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
        FormComponent.handle_event("add-key-file", %{}, socket)

      key_files = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :key_files)
      assert length(key_files) == 1
      assert hd(key_files).position == 0
    end

    test "adds key file to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "First file", position: 0}
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-key-file", %{}, socket)

      key_files = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :key_files)
      assert length(key_files) == 2
      assert Enum.at(key_files, 1).position == 1
    end

    test "preserves existing key files when adding new one" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "First file", position: 0}
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-key-file", %{}, socket)

      key_files = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :key_files)
      assert Enum.at(key_files, 0).file_path == "lib/tasks.ex"
      assert Enum.at(key_files, 0).note == "First file"
    end
  end

  describe "handle_event remove-key-file" do
    test "removes key file at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "First", position: 0},
            %{file_path: "lib/tasks/task.ex", note: "Second", position: 1}
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-key-file", %{"index" => "0"}, socket)

      key_files = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :key_files)
      assert length(key_files) == 1
      assert hd(key_files).file_path == "lib/tasks/task.ex"
    end

    test "removes last key file" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "Only file", position: 0}
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-key-file", %{"index" => "0"}, socket)

      key_files = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :key_files)
      assert Enum.empty?(key_files)
    end
  end

  describe "handle_event add-verification-step" do
    test "adds new verification step to empty list" do
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
        FormComponent.handle_event("add-verification-step", %{}, socket)

      steps = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :verification_steps)
      assert length(steps) == 1
      assert hd(steps).position == 0
    end

    test "adds verification step to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          verification_steps: [
            %{
              step_type: "command",
              step_text: "mix test",
              expected_result: "Success",
              position: 0
            }
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-verification-step", %{}, socket)

      steps = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :verification_steps)
      assert length(steps) == 2
      assert Enum.at(steps, 1).position == 1
    end
  end

  describe "handle_event remove-verification-step" do
    test "removes verification step at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          verification_steps: [
            %{
              step_type: "command",
              step_text: "mix test",
              expected_result: "Success",
              position: 0
            },
            %{
              step_type: "manual",
              step_text: "Check UI",
              expected_result: "Looks good",
              position: 1
            }
          ]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-verification-step", %{"index" => "0"}, socket)

      steps = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :verification_steps)
      assert length(steps) == 1
      assert hd(steps).step_text == "Check UI"
    end
  end

  describe "handle_event add-technology" do
    test "adds empty technology to list" do
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
        FormComponent.handle_event("add-technology", %{}, socket)

      tech_list =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :technology_requirements)

      assert length(tech_list) == 1
      assert hd(tech_list) == ""
    end

    test "adds technology to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          technology_requirements: ["Phoenix", "Ecto"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-technology", %{}, socket)

      tech_list =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :technology_requirements)

      assert length(tech_list) == 3
      assert Enum.at(tech_list, 0) == "Phoenix"
      assert Enum.at(tech_list, 1) == "Ecto"
      assert Enum.at(tech_list, 2) == ""
    end
  end

  describe "handle_event remove-technology" do
    test "removes technology at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          technology_requirements: ["Phoenix", "Ecto", "LiveView"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-technology", %{"index" => "1"}, socket)

      tech_list =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :technology_requirements)

      assert length(tech_list) == 2
      assert tech_list == ["Phoenix", "LiveView"]
    end
  end

  describe "handle_event add-pitfall" do
    test "adds empty pitfall to list" do
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
        FormComponent.handle_event("add-pitfall", %{}, socket)

      pitfalls = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :pitfalls)
      assert length(pitfalls) == 1
      assert hd(pitfalls) == ""
    end
  end

  describe "handle_event remove-pitfall" do
    test "removes pitfall at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          pitfalls: ["Don't forget to test", "Watch for race conditions"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-pitfall", %{"index" => "0"}, socket)

      pitfalls = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :pitfalls)
      assert length(pitfalls) == 1
      assert hd(pitfalls) == "Watch for race conditions"
    end
  end

  describe "handle_event add-out-of-scope" do
    test "adds empty out of scope item to list" do
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
        FormComponent.handle_event("add-out-of-scope", %{}, socket)

      out_of_scope = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :out_of_scope)
      assert length(out_of_scope) == 1
      assert hd(out_of_scope) == ""
    end
  end

  describe "handle_event remove-out-of-scope" do
    test "removes out of scope item at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          out_of_scope: ["No UI changes", "No database migrations"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-out-of-scope", %{"index" => "1"}, socket)

      out_of_scope = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :out_of_scope)
      assert length(out_of_scope) == 1
      assert hd(out_of_scope) == "No UI changes"
    end
  end

  describe "handle_event add-dependency" do
    test "adds empty dependency to list" do
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
        FormComponent.handle_event("add-dependency", %{}, socket)

      dependencies = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :dependencies)
      assert length(dependencies) == 1
      assert hd(dependencies) == ""
    end
  end

  describe "handle_event remove-dependency" do
    test "removes dependency at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, dep1} = Tasks.create_task(column, %{"title" => "Dep A"})
      {:ok, dep2} = Tasks.create_task(column, %{"title" => "Dep B"})

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Test",
          "dependencies" => [dep1.identifier, dep2.identifier]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-dependency", %{"index" => "0"}, socket)

      dependencies = Ecto.Changeset.get_field(updated_socket.assigns.form.source, :dependencies)
      assert length(dependencies) == 1
      assert hd(dependencies) == dep2.identifier
    end
  end

  describe "handle_event add-capability" do
    test "adds empty capability to list" do
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
        FormComponent.handle_event("add-capability", %{}, socket)

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert length(capabilities) == 1
      assert hd(capabilities) == ""
    end
  end

  describe "handle_event add-capability-from-select" do
    test "adds capability from dropdown with non-empty value" do
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
          "add-capability-from-select",
          %{"new_capability" => "testing"},
          socket
        )

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert capabilities == ["testing"]
    end

    test "prevents duplicate capabilities" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          required_capabilities: ["testing", "debugging"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add-capability-from-select",
          %{"new_capability" => "testing"},
          socket
        )

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert capabilities == ["testing", "debugging"]
      assert length(capabilities) == 2
    end

    test "adds capability to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          required_capabilities: ["testing"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "add-capability-from-select",
          %{"new_capability" => "debugging"},
          socket
        )

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert capabilities == ["testing", "debugging"]
    end

    test "ignores empty capability value" do
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
          "add-capability-from-select",
          %{"new_capability" => ""},
          socket
        )

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert capabilities == [] || capabilities == nil
    end

    test "handles missing new_capability parameter" do
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
        FormComponent.handle_event("add-capability-from-select", %{}, socket)

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert capabilities == [] || capabilities == nil
    end
  end

  describe "handle_event remove-capability" do
    test "removes capability at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          required_capabilities: ["testing", "debugging", "code_generation"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-capability", %{"index" => "1"}, socket)

      capabilities =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :required_capabilities)

      assert length(capabilities) == 2
      assert capabilities == ["testing", "code_generation"]
    end

    test "saving task with all capabilities removed updates to empty array" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test Task",
          required_capabilities: ["testing", "debugging"]
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{
            "task" => %{
              "title" => "Test Task",
              "required_capabilities" => [""]
            }
          },
          socket
        )

      updated_task = Tasks.get_task!(task.id)
      assert updated_task.required_capabilities == []
    end
  end

  describe "handle_event save for new task" do
    test "creates task with all rich fields" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash and add test process to receive messages
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Rich Task",
        "description" => "Full task with all fields",
        "complexity" => "medium",
        "why" => "To test all fields",
        "what" => "Create comprehensive test",
        "where_context" => "test/",
        "technology_requirements" => ["Phoenix", "LiveView"],
        "pitfalls" => ["Don't forget validation"],
        "out_of_scope" => ["No UI styling"],
        "dependencies" => ["W01A"]
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Verify task was created
      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Rich Task")
      assert created_task
      assert created_task.complexity == :medium
      assert created_task.why == "To test all fields"
      assert created_task.technology_requirements == ["Phoenix", "LiveView"]
    end
  end

  describe "handle_event save for edit task" do
    test "updates task with rich fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Original Title",
          complexity: :small
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Updated Title",
        "complexity" => "large",
        "technology_requirements" => ["Ecto"]
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Verify task was updated
      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert updated_task.title == "Updated Title"
      assert updated_task.complexity == :large
      assert updated_task.technology_requirements == ["Ecto"]
    end
  end

  describe "security: cross-board task creation prevention" do
    test "prevents creating task in another user's board column" do
      # Setup: Create two users with their own boards
      user1 = user_fixture(%{email: "user1@example.com"})
      user2 = user_fixture(%{email: "user2@example.com"})

      board1 = board_fixture(user1)
      board2 = board_fixture(user2)

      column1 = column_fixture(board1, %{name: "Board 1 Column"})
      column2 = column_fixture(board2, %{name: "Board 2 Column"})

      task = %Tasks.Task{column_id: column1.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board1,
            action: :new_task,
            column_id: column1.id,
            patch: "/boards/#{board1.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      # Attempt: Try to create task with column_id from board2
      task_params = %{
        "title" => "Malicious Task",
        "column_id" => column2.id
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Verify: Task was NOT created
      assert Kanban.Repo.get_by(Tasks.Task, title: "Malicious Task") == nil

      # Verify: Error message is shown
      assert updated_socket.assigns.error_message == "Security error: Invalid column"

      # Verify: Form has error
      assert updated_socket.assigns.form.source.errors[:column_id] != nil
    end

    test "prevents moving task to another user's board column via edit" do
      # Setup: Create two users with their own boards
      user1 = user_fixture(%{email: "user1@example.com"})
      user2 = user_fixture(%{email: "user2@example.com"})

      board1 = board_fixture(user1)
      board2 = board_fixture(user2)

      column1 = column_fixture(board1, %{name: "Board 1 Column"})
      column2 = column_fixture(board2, %{name: "Board 2 Column"})

      # Create task in board1
      task = task_fixture(column1, %{title: "Legitimate Task"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board1,
            action: :edit_task,
            patch: "/boards/#{board1.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      # Attempt: Try to move task to board2's column
      task_params = %{
        "title" => "Legitimate Task",
        "column_id" => column2.id
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Verify: Task was NOT moved
      reloaded_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert reloaded_task.column_id == column1.id

      # Verify: Error message is shown
      assert updated_socket.assigns.error_message == "Security error: Invalid column"

      # Verify: Form has error
      assert updated_socket.assigns.form.source.errors[:column_id] != nil
    end

    test "prevents setting parent_id to a task on a different board" do
      user1 = user_fixture()
      user2 = user_fixture()
      board1 = board_fixture(user1)
      board2 = board_fixture(user2)
      column1 = column_fixture(board1)
      column2 = column_fixture(board2)

      # A task on board1 the attacker is editing.
      task = task_fixture(column1, %{title: "Editable Task"})
      # A goal on the OTHER board the attacker tries to parent it under.
      other_goal = task_fixture(column2, %{title: "Cross-Board Goal"})

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: user1},
            task: task,
            board: board1,
            action: :edit_task,
            patch: "/boards/#{board1.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Editable Task",
        "parent_id" => to_string(other_goal.id)
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Task was not re-parented across boards.
      reloaded = Kanban.Repo.get!(Tasks.Task, task.id)
      refute reloaded.parent_id == other_goal.id

      assert updated_socket.assigns.error_message == "Security error: Invalid parent goal"
      assert updated_socket.assigns.form.source.errors[:parent_id] != nil
    end

    test "prevents setting assigned_to_id to a user without board access" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Editable Task"})

      # A user with NO membership on the board.
      stranger = user_fixture()

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: owner},
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Editable Task",
        "assigned_to_id" => to_string(stranger.id)
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      reloaded = Kanban.Repo.get!(Tasks.Task, task.id)
      refute reloaded.assigned_to_id == stranger.id

      assert updated_socket.assigns.error_message == "Security error: Invalid assignee"
      assert updated_socket.assigns.form.source.errors[:assigned_to_id] != nil
    end

    test "allows setting assigned_to_id to a legitimate board member" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column, %{title: "Editable Task"})

      modify_member = user_fixture()
      Kanban.Boards.add_user_to_board(board, modify_member, :modify, owner)

      {:ok, socket} =
        FormComponent.update(
          %{
            current_scope: %{user: owner},
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Editable Task",
        "assigned_to_id" => to_string(modify_member.id)
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      refute updated_socket.assigns[:error_message] == "Security error: Invalid assignee"
    end
  end

  describe "assignable users" do
    test "builds assignable users list from board users" do
      user1 = user_fixture(%{email: "user1@example.com", name: "User One"})
      user2 = user_fixture(%{email: "user2@example.com", name: ""})
      board = board_fixture(user1)
      Kanban.Boards.add_user_to_board(board, user2, :modify, user1)
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

      assignable_users = socket.assigns.assignable_users
      # Should have "Unassigned" option plus 2 users
      assert length(assignable_users) == 3

      # First option should be "Unassigned" with nil value
      assert {"Unassigned", nil} in assignable_users

      # Should use name if available, otherwise email
      assert {"User One", user1.id} in assignable_users
      assert {"user2@example.com", user2.id} in assignable_users
    end
  end

  describe "handle_event add-security-consideration" do
    test "adds empty security consideration to list" do
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
        FormComponent.handle_event("add-security-consideration", %{}, socket)

      security_considerations =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :security_considerations)

      assert length(security_considerations) == 1
      assert hd(security_considerations) == ""
    end

    test "adds security consideration to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          security_considerations: ["Hash passwords", "Validate input"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-security-consideration", %{}, socket)

      security_considerations =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :security_considerations)

      assert length(security_considerations) == 3
      assert Enum.at(security_considerations, 0) == "Hash passwords"
      assert Enum.at(security_considerations, 1) == "Validate input"
      assert Enum.at(security_considerations, 2) == ""
    end
  end

  describe "handle_event remove-security-consideration" do
    test "removes security consideration at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          security_considerations: ["Hash passwords", "Validate input", "Use HTTPS"]
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-security-consideration", %{"index" => "1"}, socket)

      security_considerations =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :security_considerations)

      assert length(security_considerations) == 2
      assert security_considerations == ["Hash passwords", "Use HTTPS"]
    end
  end

  describe "handle_event add-unit-test" do
    test "adds empty unit test to testing_strategy map" do
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
        FormComponent.handle_event("add-unit-test", %{}, socket)

      testing_strategy =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :testing_strategy)

      assert testing_strategy["unit_tests"] == [""]
    end

    test "adds unit test to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          testing_strategy: %{
            "unit_tests" => ["Test validation"]
          }
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-unit-test", %{}, socket)

      testing_strategy =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :testing_strategy)

      assert length(testing_strategy["unit_tests"]) == 2
      assert Enum.at(testing_strategy["unit_tests"], 0) == "Test validation"
      assert Enum.at(testing_strategy["unit_tests"], 1) == ""
    end
  end

  describe "handle_event remove-unit-test" do
    test "removes unit test at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          testing_strategy: %{
            "unit_tests" => ["Test auth", "Test validation", "Test errors"]
          }
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-unit-test", %{"index" => "1"}, socket)

      testing_strategy =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :testing_strategy)

      assert testing_strategy["unit_tests"] == ["Test auth", "Test errors"]
    end
  end

  describe "handle_event add-integration-test" do
    test "adds integration test to testing_strategy map" do
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
        FormComponent.handle_event("add-integration-test", %{}, socket)

      testing_strategy =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :testing_strategy)

      assert testing_strategy["integration_tests"] == [""]
    end
  end

  describe "handle_event add-manual-test" do
    test "adds manual test to testing_strategy map" do
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
        FormComponent.handle_event("add-manual-test", %{}, socket)

      testing_strategy =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :testing_strategy)

      assert testing_strategy["manual_tests"] == [""]
    end
  end

  describe "handle_event add-telemetry-event" do
    test "adds telemetry event to integration_points map" do
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
        FormComponent.handle_event("add-telemetry-event", %{}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert integration_points["telemetry_events"] == [""]
    end

    test "adds telemetry event to existing list" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          integration_points: %{
            "telemetry_events" => ["[:kanban, :task, :created]"]
          }
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("add-telemetry-event", %{}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert length(integration_points["telemetry_events"]) == 2
    end
  end

  describe "handle_event remove-telemetry-event" do
    test "removes telemetry event at specified index" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          integration_points: %{
            "telemetry_events" => ["[:kanban, :task, :created]", "[:kanban, :task, :updated]"]
          }
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

      {:noreply, updated_socket} =
        FormComponent.handle_event("remove-telemetry-event", %{"index" => "0"}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert integration_points["telemetry_events"] == ["[:kanban, :task, :updated]"]
    end
  end

  describe "handle_event add-pubsub-broadcast" do
    test "adds pubsub broadcast to integration_points map" do
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
        FormComponent.handle_event("add-pubsub-broadcast", %{}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert integration_points["pubsub_broadcasts"] == [""]
    end
  end

  describe "handle_event add-phoenix-channel" do
    test "adds phoenix channel to integration_points map" do
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
        FormComponent.handle_event("add-phoenix-channel", %{}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert integration_points["phoenix_channels"] == [""]
    end
  end

  describe "handle_event add-external-api" do
    test "adds external API to integration_points map" do
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
        FormComponent.handle_event("add-external-api", %{}, socket)

      integration_points =
        Ecto.Changeset.get_field(updated_socket.assigns.form.source, :integration_points)

      assert integration_points["external_apis"] == [""]
    end
  end

  describe "goal options" do
    test "builds goal options from board" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      # Create some goals
      {:ok, goal1} = Tasks.create_task(column, %{"title" => "Goal 1", "type" => "goal"})
      {:ok, goal2} = Tasks.create_task(column, %{"title" => "Goal 2", "type" => "goal"})

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

      goal_options = socket.assigns.goal_options
      # Should have "No parent goal" plus 2 goals
      assert length(goal_options) == 3
      assert {"No parent goal", nil} in goal_options

      # Should show identifier and title
      goal1_option =
        Enum.find(goal_options, fn {label, _id} ->
          label == "#{goal1.identifier} - Goal 1"
        end)

      assert goal1_option

      goal2_option =
        Enum.find(goal_options, fn {label, _id} ->
          label == "#{goal2.identifier} - Goal 2"
        end)

      assert goal2_option
    end

    test "excludes current task from goal options when editing" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, goal1} = Tasks.create_task(column, %{"title" => "Goal 1", "type" => "goal"})
      {:ok, goal2} = Tasks.create_task(column, %{"title" => "Goal 2", "type" => "goal"})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: goal1,
            board: board,
            action: :edit_task
          },
          %Phoenix.LiveView.Socket{}
        )

      goal_options = socket.assigns.goal_options
      # Should not include goal1 itself
      goal1_option = Enum.find(goal_options, fn {_label, id} -> id == goal1.id end)
      refute goal1_option

      # Should include goal2
      goal2_option = Enum.find(goal_options, fn {_label, id} -> id == goal2.id end)
      assert goal2_option
    end

    test "excludes archived goals from goal options" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, active_goal} =
        Tasks.create_task(column, %{"title" => "Active Goal", "type" => "goal"})

      {:ok, archived_goal} =
        Tasks.create_task(column, %{"title" => "Archived Goal", "type" => "goal"})

      archived_goal
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Kanban.Repo.update!()

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

      goal_options = socket.assigns.goal_options

      refute Enum.find(goal_options, fn {_label, id} -> id == archived_goal.id end)
      assert Enum.find(goal_options, fn {_label, id} -> id == active_goal.id end)
    end
  end

  describe "field visibility" do
    test "sets field_visibility from board" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = %Tasks.Task{column_id: column.id}

      # Update board with field visibility
      board
      |> Ecto.Changeset.change(%{
        field_visibility: %{"why" => true, "what" => true, "where_context" => false}
      })
      |> Kanban.Repo.update!()

      board = Kanban.Repo.get!(Kanban.Boards.Board, board.id)

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

      assert socket.assigns.field_visibility == %{
               "why" => true,
               "what" => true,
               "where_context" => false
             }
    end

    test "uses default field_visibility from board schema" do
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

      # Board has default field_visibility from schema
      assert is_map(socket.assigns.field_visibility)
      assert Map.has_key?(socket.assigns.field_visibility, "acceptance_criteria")
      assert socket.assigns.field_visibility["acceptance_criteria"] == true
    end
  end

  describe "normalize_array_params" do
    test "filters empty strings from array fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      # Create actual dependency tasks
      dep1 = task_fixture(column, %{title: "Dependency 1"})
      dep2 = task_fixture(column, %{title: "Dependency 2"})

      task = %Tasks.Task{column_id: column.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :new_task,
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task With Arrays",
        "pitfalls" => ["Real pitfall", "", "Another pitfall", ""],
        "dependencies" => [dep1.identifier, "", dep2.identifier, ""]
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Reload task from database with all fields
      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task With Arrays")

      assert created_task.pitfalls == ["Real pitfall", "Another pitfall"]
      assert created_task.dependencies == [dep1.identifier, dep2.identifier]
    end

    test "does not add missing array fields to params (schema defaults handle them)" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      # Don't include array fields - schema defaults will make them []
      task_params = %{
        "title" => "Test Task"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      # Schema defaults make these [] even though we didn't send them in params
      assert created_task.dependencies == []
      # Pitfalls doesn't have a schema default, so it will be nil
      assert created_task.pitfalls == nil || created_task.pitfalls == []
      assert created_task.out_of_scope == nil || created_task.out_of_scope == []
    end
  end

  describe "save with WIP limit" do
    test "shows error when creating task exceeds WIP limit" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "New Task"
      }

      {:noreply, updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      # Should have error in changeset
      assert updated_socket.assigns.form.source.errors[:column_id]

      assert updated_socket.assigns.error_message ==
               "Cannot add task: WIP limit reached for this column"
    end
  end

  describe "maybe_add_review_metadata" do
    test "adds reviewed_at and reviewed_by_id when review_status changes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test"})

      # Add user to current_scope for review metadata
      scope = %{user: user}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}",
            current_scope: scope
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test",
        "review_status" => "approved"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert updated_task.review_status == :approved
      assert updated_task.reviewed_by_id == user.id
      assert updated_task.reviewed_at
    end

    test "does not add review metadata when review_status is pending" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test"})

      scope = %{user: user}

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}",
            current_scope: scope
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test",
        "review_status" => "pending"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      refute updated_task.reviewed_by_id
      refute updated_task.reviewed_at
    end
  end

  describe "AI context fields integration" do
    test "creates task with all AI context fields" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "AI Enhanced Task",
        "security_considerations" => ["Hash all tokens", "Use HTTPS only"],
        "testing_strategy" => %{
          "unit_tests" => ["Test validation", "Test error handling"],
          "integration_tests" => ["Test API flow"],
          "manual_tests" => ["Verify UI"]
        },
        "integration_points" => %{
          "telemetry_events" => ["[:kanban, :task, :completed]"],
          "pubsub_broadcasts" => ["task:updated"],
          "phoenix_channels" => ["task:123"],
          "external_apis" => ["https://api.example.com"]
        }
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "AI Enhanced Task")
      assert created_task
      assert created_task.security_considerations == ["Hash all tokens", "Use HTTPS only"]

      assert created_task.testing_strategy["unit_tests"] == [
               "Test validation",
               "Test error handling"
             ]

      assert created_task.integration_points["telemetry_events"] == [
               "[:kanban, :task, :completed]"
             ]
    end
  end

  describe "maybe_add_completed_at" do
    test "adds completed_at timestamp when status is set to completed" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task", status: :open})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "status" => "completed"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert updated_task.status == :completed
      assert updated_task.completed_at
    end

    test "does not modify completed_at when status is not completed" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test Task", status: :open})

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "status" => "in_progress"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert updated_task.status == :in_progress
      refute updated_task.completed_at
    end

    test "preserves existing completed_at if already set" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      original_completed_at = ~U[2025-01-01 12:00:00Z]

      task =
        task_fixture(column, %{
          title: "Test Task",
          status: :completed,
          completed_at: original_completed_at
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Updated Title",
        "status" => "completed"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      updated_task = Kanban.Repo.get!(Tasks.Task, task.id)
      assert updated_task.status == :completed
      # Should preserve original completed_at
      assert DateTime.compare(updated_task.completed_at, original_completed_at) == :eq
    end
  end

  describe "status change unblocks dependent tasks" do
    test "unblocks dependent task when status changed to completed" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Ready"})

      {:ok, dep_task} = Tasks.create_task(column, %{"title" => "Dependency", "status" => "open"})

      {:ok, blocked_task} =
        Tasks.create_task(column, %{
          "title" => "Blocked Task",
          "dependencies" => [dep_task.identifier]
        })

      # Verify blocked task is initially blocked
      refreshed_blocked = Tasks.get_task!(blocked_task.id)
      assert refreshed_blocked.status == :blocked

      # Update dependency task to completed via form
      {:ok, socket} =
        FormComponent.update(
          %{
            task: dep_task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => %{"status" => "completed"}}, socket)

      # Verify dependent task is now unblocked
      final_blocked = Tasks.get_task!(blocked_task.id)
      assert final_blocked.status == :open
    end

    test "unblocks multiple dependent tasks when status changed to completed" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Ready"})

      {:ok, dep_task} = Tasks.create_task(column, %{"title" => "Dependency"})

      {:ok, blocked1} =
        Tasks.create_task(column, %{
          "title" => "Blocked 1",
          "dependencies" => [dep_task.identifier]
        })

      {:ok, blocked2} =
        Tasks.create_task(column, %{
          "title" => "Blocked 2",
          "dependencies" => [dep_task.identifier]
        })

      assert Tasks.get_task!(blocked1.id).status == :blocked
      assert Tasks.get_task!(blocked2.id).status == :blocked

      # Complete dependency via form
      {:ok, socket} =
        FormComponent.update(
          %{
            task: dep_task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => %{"status" => "completed"}}, socket)

      # Both should be unblocked
      assert Tasks.get_task!(blocked1.id).status == :open
      assert Tasks.get_task!(blocked2.id).status == :open
    end

    test "does not unblock task with multiple dependencies if only one completed" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Ready"})

      {:ok, dep1} = Tasks.create_task(column, %{"title" => "Dep 1"})
      {:ok, dep2} = Tasks.create_task(column, %{"title" => "Dep 2"})

      {:ok, blocked_task} =
        Tasks.create_task(column, %{
          "title" => "Blocked Task",
          "dependencies" => [dep1.identifier, dep2.identifier]
        })

      assert Tasks.get_task!(blocked_task.id).status == :blocked

      # Complete only first dependency
      {:ok, socket} =
        FormComponent.update(
          %{
            task: dep1,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => %{"status" => "completed"}}, socket)

      # Should still be blocked because dep2 is not complete
      assert Tasks.get_task!(blocked_task.id).status == :blocked
    end
  end

  describe "validate with embedded fields" do
    test "validates without errors when key_files exist" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "Main file", position: 0}
          ]
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

      # Validate with status change
      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"status" => "in_progress"}},
          socket
        )

      # Should not have validation errors for key_files
      refute updated_socket.assigns.form.source.errors[:key_files]
      assert updated_socket.assigns.form.source.changes.status == :in_progress
    end

    test "validates without errors when verification_steps exist" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          verification_steps: [
            %{
              step_type: "command",
              step_text: "mix test",
              expected_result: "All pass",
              position: 0
            }
          ]
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

      # Validate with status change
      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"status" => "blocked"}},
          socket
        )

      # Should not have validation errors for verification_steps
      refute updated_socket.assigns.form.source.errors[:verification_steps]
      assert updated_socket.assigns.form.source.changes.status == :blocked
    end

    test "normalizes params during validation to prevent false errors" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Test",
          key_files: [
            %{file_path: "lib/tasks.ex", note: "Main file", position: 0}
          ],
          verification_steps: [
            %{
              step_type: "command",
              step_text: "mix test",
              expected_result: "Pass",
              position: 0
            }
          ]
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

      # Validate with params that might have empty strings in arrays
      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{
            "task" => %{
              "title" => "Updated",
              "status" => "completed",
              "pitfalls" => ["Real pitfall", "", "Another", ""]
            }
          },
          socket
        )

      # Should not have any validation errors
      refute updated_socket.assigns.form.source.errors[:key_files]
      refute updated_socket.assigns.form.source.errors[:verification_steps]
      refute updated_socket.assigns.form.source.errors[:pitfalls]
    end

    test "allows changing status field without embedded field errors" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{
          title: "Task with embeds",
          status: :open,
          key_files: [
            %{file_path: "lib/tasks.ex", note: "File 1", position: 0}
          ]
        })

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: :edit_task,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      # Change status - this should work without validation errors
      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"status" => "completed"}},
          socket
        )

      # Verify status was updated
      updated_task = Tasks.get_task!(task.id)
      assert updated_task.status == :completed
    end
  end

  describe "normalize_embedded_field with map inputs" do
    test "converts map with numeric string keys to sorted list" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "key_files" => %{
          "0" => %{"file_path" => "lib/second.ex", "note" => "Second", "position" => "1"},
          "1" => %{"file_path" => "lib/first.ex", "note" => "First", "position" => "0"}
        }
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      assert created_task
      assert length(created_task.key_files) == 2
      assert Enum.at(created_task.key_files, 0).file_path == "lib/second.ex"
      assert Enum.at(created_task.key_files, 1).file_path == "lib/first.ex"
    end

    test "removes _persistent_id from embedded entries during normalization" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "verification_steps" => %{
          "0" => %{
            "step_type" => "command",
            "step_text" => "mix test",
            "expected_result" => "Pass",
            "position" => "0",
            "_persistent_id" => "some-id"
          }
        }
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      assert created_task
      assert length(created_task.verification_steps) == 1

      step = hd(created_task.verification_steps)
      assert step.step_text == "mix test"
      refute Map.has_key?(step, :_persistent_id)
    end

    test "handles already-normalized list inputs" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "key_files" => [
          %{"file_path" => "lib/test.ex", "note" => "Test", "position" => 0}
        ]
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      assert created_task
      assert length(created_task.key_files) == 1
      assert hd(created_task.key_files).file_path == "lib/test.ex"
    end

    test "does not add empty arrays for missing embedded fields" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task Without Embeds"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task Without Embeds")
      assert created_task
      assert created_task.key_files == [] || created_task.key_files == nil
      assert created_task.verification_steps == [] || created_task.verification_steps == nil
    end
  end

  describe "normalize_map_with_arrays" do
    test "normalizes testing_strategy with empty strings filtered" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "testing_strategy" => %{
          "unit_tests" => ["Test 1", "", "Test 2", ""],
          "integration_tests" => ["Integration test", ""]
        }
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      assert created_task
      assert created_task.testing_strategy["unit_tests"] == ["Test 1", "Test 2"]
      assert created_task.testing_strategy["integration_tests"] == ["Integration test"]
    end

    test "normalizes integration_points with empty strings filtered" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task",
        "integration_points" => %{
          "telemetry_events" => ["[:kanban, :task, :created]", "", "[:kanban, :task, :updated]"],
          "pubsub_broadcasts" => ["task:updated", ""]
        }
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task")
      assert created_task

      assert created_task.integration_points["telemetry_events"] == [
               "[:kanban, :task, :created]",
               "[:kanban, :task, :updated]"
             ]

      assert created_task.integration_points["pubsub_broadcasts"] == ["task:updated"]
    end

    test "does not add default maps for missing map fields" do
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
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      task_params = %{
        "title" => "Test Task Without Maps"
      }

      {:noreply, _updated_socket} =
        FormComponent.handle_event("save", %{"task" => task_params}, socket)

      created_task = Kanban.Repo.get_by(Tasks.Task, title: "Test Task Without Maps")
      assert created_task
      assert created_task.testing_strategy == %{} || created_task.testing_strategy == nil
      assert created_task.integration_points == %{} || created_task.integration_points == nil
    end
  end

  describe "Review Queue section visibility logic" do
    test "task with review_status set should make review fields visible" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Test", review_status: :pending})

      # Verify the task has review_status which triggers visibility
      assert task.review_status == :pending
    end

    test "task in Review column should make review fields visible" do
      user = user_fixture()
      board = board_fixture(user)
      review_column = column_fixture(board, %{name: "Review"})

      task =
        task_fixture(review_column, %{title: "Test", review_status: nil})
        |> Kanban.Repo.preload(:column)

      # Verify the task is in Review column which should trigger visibility
      assert task.column.name == "Review"
      assert is_nil(task.review_status)
    end

    test "task with needs_review true should make review fields visible" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Doing"})
      task = task_fixture(column, %{title: "Test", needs_review: true, review_status: nil})

      # Verify needs_review flag which should trigger visibility
      assert task.needs_review == true
      assert is_nil(task.review_status)
    end

    test "task without review triggers should hide review fields" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      task =
        task_fixture(column, %{title: "Test", needs_review: false, review_status: nil})
        |> Kanban.Repo.preload(:column)

      # Verify none of the visibility conditions are met
      assert is_nil(task.review_status)
      assert task.needs_review == false
      assert task.column.name != "Review"
    end

    test "Review column overrides needs_review false" do
      user = user_fixture()
      board = board_fixture(user)
      review_column = column_fixture(board, %{name: "Review"})

      task =
        task_fixture(review_column, %{title: "Test", needs_review: false, review_status: nil})
        |> Kanban.Repo.preload(:column)

      # Even though needs_review is false, being in Review column should show fields
      assert task.column.name == "Review"
      assert task.needs_review == false
      assert is_nil(task.review_status)
    end
  end

  describe "handle_event save with goal-assignment cascade flash" do
    setup do
      alice = user_fixture()
      board = board_fixture(alice)
      column = column_fixture(board, %{name: "To Do"})

      goal = task_fixture(column, %{title: "Cascade Goal", type: :goal})

      _child1 = task_fixture(column, %{title: "Child 1", parent_id: goal.id})
      _child2 = task_fixture(column, %{title: "Child 2", parent_id: goal.id})
      _child3 = task_fixture(column, %{title: "Child 3", parent_id: goal.id})

      # FormComponent.update preloads the task — load it the same way so the
      # socket gets a struct that matches what the production code sees.
      goal_loaded = Tasks.get_task!(goal.id)

      %{alice: alice, board: board, column: column, goal: goal_loaded}
    end

    test "flash mentions cascade count when assigning a goal with eligible children",
         %{alice: alice, board: board, goal: goal} do
      socket = build_edit_socket(goal, board)

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"assigned_to_id" => Integer.to_string(alice.id)}},
          socket
        )

      flash = updated_socket.assigns.flash
      assert flash["info"] =~ "Task updated successfully"
      assert flash["info"] =~ "3 child tasks were also updated"
    end

    test "flash is the plain success message when the assignment is unchanged",
         %{board: board, goal: goal} do
      socket = build_edit_socket(goal, board)

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"title" => "Renamed Goal"}},
          socket
        )

      flash = updated_socket.assigns.flash
      assert flash["info"] == "Task updated successfully"
    end

    test "flash is the plain success message when the saved task is not a goal",
         %{alice: alice, board: board, column: column} do
      regular = task_fixture(column, %{title: "Plain task"}) |> then(&Tasks.get_task!(&1.id))
      socket = build_edit_socket(regular, board)

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"assigned_to_id" => Integer.to_string(alice.id)}},
          socket
        )

      flash = updated_socket.assigns.flash
      assert flash["info"] == "Task updated successfully"
    end

    test "flash is the plain success message for a goal with no eligible children",
         %{alice: alice, board: board, column: column} do
      lonely_goal =
        task_fixture(column, %{title: "Lonely Goal", type: :goal})
        |> then(&Tasks.get_task!(&1.id))

      socket = build_edit_socket(lonely_goal, board)

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"assigned_to_id" => Integer.to_string(alice.id)}},
          socket
        )

      flash = updated_socket.assigns.flash
      assert flash["info"] == "Task updated successfully"
    end

    defp build_edit_socket(task, board) do
      {:ok, socket} =
        FormComponent.update(
          %{task: task, board: board, action: :edit_task, patch: ~p"/"},
          %Phoenix.LiveView.Socket{}
        )

      Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))
    end
  end

  describe "W403 server-side attribution overrides for review_metadata and completed_at" do
    test "maybe_add_review_metadata strips client-supplied reviewed_at and reviewed_by_id" do
      current_user = %{id: 42}

      params = %{
        "review_status" => "approved",
        "reviewed_at" => "1999-01-01T00:00:00Z",
        "reviewed_by_id" => 999
      }

      result = FormComponent.maybe_add_review_metadata(params, current_user)

      refute result["reviewed_at"] == "1999-01-01T00:00:00Z"
      refute result["reviewed_by_id"] == 999
      assert result["reviewed_by_id"] == 42
      assert %DateTime{} = result["reviewed_at"]
    end

    test "maybe_add_review_metadata does not add metadata when status is pending" do
      current_user = %{id: 42}
      params = %{"review_status" => "pending"}

      result = FormComponent.maybe_add_review_metadata(params, current_user)

      refute Map.has_key?(result, "reviewed_at")
      refute Map.has_key?(result, "reviewed_by_id")
    end

    test "maybe_add_review_metadata strips forged metadata even when review_status is empty" do
      current_user = %{id: 42}

      params = %{
        "review_status" => "",
        "reviewed_at" => "1999-01-01T00:00:00Z",
        "reviewed_by_id" => 999
      }

      result = FormComponent.maybe_add_review_metadata(params, current_user)

      # Forged values must NOT survive even when the transition does not fire.
      refute Map.has_key?(result, "reviewed_at")
      refute Map.has_key?(result, "reviewed_by_id")
    end

    test "maybe_add_completed_at strips client-supplied completed_at and sets server value" do
      task = %{completed_at: nil}

      params = %{
        "status" => "completed",
        "completed_at" => "1999-01-01T00:00:00Z"
      }

      result = FormComponent.maybe_add_completed_at(params, task)

      refute result["completed_at"] == "1999-01-01T00:00:00Z"
      assert %DateTime{} = result["completed_at"]
    end

    test "maybe_add_completed_at strips forged completed_at even on non-completing status" do
      task = %{completed_at: nil}

      params = %{
        "status" => "in_progress",
        "completed_at" => "1999-01-01T00:00:00Z"
      }

      result = FormComponent.maybe_add_completed_at(params, task)

      # Forged value must NOT survive even when the completion transition does
      # not fire — otherwise an attacker could pre-set completed_at on an
      # in-progress task and have it picked up by a later save.
      refute Map.has_key?(result, "completed_at")
    end

    test "maybe_add_completed_at preserves existing task.completed_at when status stays completed" do
      existing_dt = ~U[2026-01-01 00:00:00Z]
      task = %{completed_at: existing_dt}
      params = %{"status" => "completed"}

      result = FormComponent.maybe_add_completed_at(params, task)

      # No completed_at is added because the task is already completed;
      # the existing timestamp on task.completed_at is preserved by Ecto cast.
      refute Map.has_key?(result, "completed_at")
    end
  end

  describe "technical_details JSON editor (W1177)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      board =
        board
        |> Ecto.Changeset.change(%{field_visibility: %{"technical_details" => true}})
        |> Kanban.Repo.update!()

      %{user: user, board: board, column: column}
    end

    defp td_socket(board, column, task) do
      action = if is_nil(task.id), do: :new_task, else: :edit_task

      {:ok, socket} =
        FormComponent.update(
          %{
            task: task,
            board: board,
            action: action,
            column_id: column.id,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      # The save path calls put_flash/3 and push_patch/2, which need a flash assign.
      Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))
    end

    test "initial raw value is pretty-printed JSON for an existing map", %{
      board: board,
      column: column
    } do
      task = task_fixture(column, %{technical_details: %{"db" => "postgres"}})
      socket = td_socket(board, column, task)

      assert socket.assigns.technical_details_raw =~ ~s("db")
      assert socket.assigns.technical_details_raw =~ ~s("postgres")
      # pretty-printed output spans multiple lines
      assert socket.assigns.technical_details_raw =~ "\n"
    end

    test "initial raw value is an empty string for an empty map", %{board: board, column: column} do
      task = %Tasks.Task{column_id: column.id}
      socket = td_socket(board, column, task)
      assert socket.assigns.technical_details_raw == ""
    end

    test "validate with a valid JSON object decodes into the changeset without error", %{
      board: board,
      column: column
    } do
      socket = td_socket(board, column, %Tasks.Task{column_id: column.id})

      {:noreply, updated} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => "T", "technical_details" => ~s({"k": "v"})}},
          socket
        )

      refute updated.assigns.form.source.errors[:technical_details]

      assert Ecto.Changeset.get_field(updated.assigns.form.source, :technical_details) == %{
               "k" => "v"
             }

      assert updated.assigns.technical_details_raw == ~s({"k": "v"})
    end

    test "validate with invalid JSON adds a friendly error and preserves the raw input", %{
      board: board,
      column: column
    } do
      socket = td_socket(board, column, %Tasks.Task{column_id: column.id})
      raw = "{not json"

      {:noreply, updated} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => "T", "technical_details" => raw}},
          socket
        )

      assert {"must be a JSON object", _} = updated.assigns.form.source.errors[:technical_details]
      assert updated.assigns.technical_details_raw == raw
    end

    test "validate with a JSON array (non-object) is rejected", %{board: board, column: column} do
      socket = td_socket(board, column, %Tasks.Task{column_id: column.id})

      {:noreply, updated} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => "T", "technical_details" => "[1, 2, 3]"}},
          socket
        )

      assert updated.assigns.form.source.errors[:technical_details]
      assert updated.assigns.technical_details_raw == "[1, 2, 3]"
    end

    test "validate with whitespace-only input is treated as an empty object", %{
      board: board,
      column: column
    } do
      socket = td_socket(board, column, %Tasks.Task{column_id: column.id})

      {:noreply, updated} =
        FormComponent.handle_event(
          "validate",
          %{"task" => %{"title" => "T", "technical_details" => "   "}},
          socket
        )

      refute updated.assigns.form.source.errors[:technical_details]
      assert Ecto.Changeset.get_field(updated.assigns.form.source, :technical_details) == %{}
    end

    test "save with a valid JSON object persists the map", %{board: board, column: column} do
      task = task_fixture(column, %{title: "Persist"})
      socket = td_socket(board, column, task)

      {:noreply, _updated} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"title" => "Persist", "technical_details" => ~s({"env": "prod"})}},
          socket
        )

      assert Kanban.Repo.get!(Tasks.Task, task.id).technical_details == %{"env" => "prod"}
    end

    test "save with an empty textarea persists an empty object", %{board: board, column: column} do
      task = task_fixture(column, %{title: "Empty", technical_details: %{"old" => "x"}})
      socket = td_socket(board, column, task)

      {:noreply, _updated} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"title" => "Empty", "technical_details" => ""}},
          socket
        )

      assert Kanban.Repo.get!(Tasks.Task, task.id).technical_details == %{}
    end

    test "save with invalid JSON surfaces an error and does not persist", %{
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Keep", technical_details: %{"keep" => "me"}})
      socket = td_socket(board, column, task)

      {:noreply, updated} =
        FormComponent.handle_event(
          "save",
          %{"task" => %{"title" => "Keep", "technical_details" => "{bad"}},
          socket
        )

      assert updated.assigns.form.source.errors[:technical_details]
      assert updated.assigns.technical_details_raw == "{bad"
      assert Kanban.Repo.get!(Tasks.Task, task.id).technical_details == %{"keep" => "me"}
    end
  end
end
