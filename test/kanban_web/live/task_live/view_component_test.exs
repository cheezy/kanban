defmodule KanbanWeb.TaskLive.ViewComponentTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.AccountsFixtures

  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory

  defp all_fields_visible do
    %{
      "acceptance_criteria" => true,
      "complexity" => true,
      "context" => true,
      "key_files" => true,
      "verification_steps" => true,
      "technical_notes" => true,
      "observability" => true,
      "error_handling" => true,
      "technology_requirements" => true,
      "pitfalls" => true,
      "out_of_scope" => true,
      "required_capabilities" => true,
      "security_considerations" => true,
      "testing_strategy" => true,
      "integration_points" => true
    }
  end

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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Description"
    end

    test "displays column name", %{task: task, column: column} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Column"
      assert result =~ column.name
    end

    test "displays Work type with blue badge", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{type: :work})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Defect"
      assert result =~ "bg-red-100 text-red-800"
    end

    test "displays Goal type with yellow badge", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{type: :goal})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Goal"
      assert result =~ "bg-yellow-100 text-yellow-800"
    end

    test "displays Low priority with blue color", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{priority: :low})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Assigned To"
      assert result =~ "John Doe"
    end

    test "displays 'Unassigned' when no user assigned", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Assigned To"
      assert result =~ "Unassigned"
    end

    test "displays created date with formatted datetime", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Created"
      assert result =~ ~r/\w+ \d{1,2}, \d{4} at \d{1,2}:\d{2} (AM|PM)/
    end

    test "displays creation history automatically created with task", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Created"
      assert result =~ "Moved"
    end

    test "displays 'No comments yet' when task has no comments", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
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
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ ~r/\w+ \d{1,2}, \d{4} at \d{1,2}:\d{2} (AM|PM)/
    end

    test "displays Edit link when can_modify is true", %{task: task, board: board} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible(),
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
          field_visibility: all_fields_visible(),
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
          field_visibility: all_fields_visible(),
          can_modify: true
        )

      refute result =~ "Edit"
    end

    test "displays priority change history with from and to priorities", %{task: task} do
      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :priority_change,
        from_priority: "low",
        to_priority: "high",
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Priority changed"
      assert result =~ "from"
      assert result =~ "low"
      assert result =~ "to"
      assert result =~ "high"
      assert result =~ "hero-exclamation-circle"
      assert result =~ "text-orange-600"
    end

    test "displays assignment history when user is assigned (nil to user)", %{task: task} do
      user = user_fixture(%{name: "Jane Smith"})

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :assignment,
        from_user_id: nil,
        to_user_id: user.id,
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Assigned to"
      assert result =~ "Jane Smith"
      assert result =~ "hero-user-circle"
      assert result =~ "text-purple-600"
    end

    test "displays assignment history when user is unassigned (user to nil)", %{task: task} do
      user = user_fixture(%{name: "Bob Jones"})

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :assignment,
        from_user_id: user.id,
        to_user_id: nil,
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Unassigned from"
      assert result =~ "Bob Jones"
      assert result =~ "hero-user-circle"
      assert result =~ "text-purple-600"
    end

    test "displays assignment history when user is reassigned (user to user)", %{task: task} do
      user1 = user_fixture(%{name: "Alice Brown"})
      user2 = user_fixture(%{name: "Charlie Green"})

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :assignment,
        from_user_id: user1.id,
        to_user_id: user2.id,
        inserted_at: ~U[2024-01-15 10:30:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Reassigned"
      assert result =~ "from"
      assert result =~ "Alice Brown"
      assert result =~ "to"
      assert result =~ "Charlie Green"
      assert result =~ "hero-user-circle"
      assert result =~ "text-purple-600"
    end

    test "displays all history types in order", %{task: task} do
      user1 = user_fixture(%{name: "John Doe"})
      user2 = user_fixture(%{name: "Jane Doe"})

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

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :priority_change,
        from_priority: "low",
        to_priority: "critical",
        inserted_at: ~U[2024-01-15 12:00:00Z]
      })
      |> Repo.insert!()

      %TaskHistory{}
      |> TaskHistory.changeset(%{
        task_id: task.id,
        type: :assignment,
        from_user_id: user1.id,
        to_user_id: user2.id,
        inserted_at: ~U[2024-01-15 13:00:00Z]
      })
      |> Repo.insert!()

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Created"
      assert result =~ "Moved"
      assert result =~ "Priority changed"
      assert result =~ "Reassigned"
      assert result =~ "hero-plus-circle"
      assert result =~ "hero-arrow-right-circle"
      assert result =~ "hero-exclamation-circle"
      assert result =~ "hero-user-circle"
    end

    # Tests for Task 03: Rich Task Details

    test "displays creator info section when created_by is set", %{board: board} do
      creator = user_fixture(%{name: "Alice Creator", email: "alice@example.com"})
      column = column_fixture(board)
      task = task_fixture(column, %{created_by_id: creator.id})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Creator Info"
      assert result =~ "Created by"
      assert result =~ "Alice Creator"
    end

    test "displays creator info with agent name when created_by_agent is set", %{board: board} do
      creator = user_fixture(%{name: "Bob User"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          created_by_id: creator.id,
          created_by_agent: "Claude-3.5-Sonnet"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Creator Info"
      assert result =~ "Agent"
      assert result =~ "Claude-3.5-Sonnet"
    end

    test "displays claim status when task is claimed", %{board: board} do
      creator = user_fixture(%{name: "Task Creator"})
      column = column_fixture(board)
      claimed_at = ~U[2024-01-15 10:00:00Z]
      claim_expires = ~U[2024-01-15 11:00:00Z]

      task =
        task_fixture(column, %{
          created_by_id: creator.id,
          claimed_at: claimed_at,
          claim_expires_at: claim_expires
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Claimed at"
      assert result =~ "Claim expires"
    end

    test "displays why/what/where context section", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          why: "To improve user experience",
          what: "Add OAuth authentication",
          where_context: "User authentication module"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Context"
      assert result =~ "Why"
      assert result =~ "To improve user experience"
      assert result =~ "What"
      assert result =~ "Add OAuth authentication"
      assert result =~ "Where"
      assert result =~ "User authentication module"
    end

    test "displays key files with file paths and notes", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          key_files: [
            %{file_path: "lib/kanban/auth.ex", note: "Main auth module", position: 0},
            %{
              file_path: "lib/kanban_web/controllers/auth_controller.ex",
              note: "OAuth controller",
              position: 1
            }
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Key Files"
      assert result =~ "lib/kanban/auth.ex"
      assert result =~ "Main auth module"
      assert result =~ "lib/kanban_web/controllers/auth_controller.ex"
      assert result =~ "OAuth controller"
    end

    test "displays verification steps with command and manual types", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          verification_steps: [
            %{
              step_type: "command",
              step_text: "mix test",
              expected_result: "All tests pass",
              position: 0
            },
            %{
              step_type: "manual",
              step_text: "Log in with OAuth",
              expected_result: "User successfully authenticated",
              position: 1
            }
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Verification Steps"
      assert result =~ "command"
      assert result =~ "mix test"
      assert result =~ "All tests pass"
      assert result =~ "manual"
      assert result =~ "Log in with OAuth"
      assert result =~ "User successfully authenticated"
    end

    test "displays implementation guidance section", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          patterns_to_follow: "Follow existing authentication patterns",
          database_changes: "Add oauth_tokens table",
          validation_rules: "Email must be unique"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Implementation Guidance"
      assert result =~ "Patterns to Follow"
      assert result =~ "Follow existing authentication patterns"
      assert result =~ "Database Changes"
      assert result =~ "Add oauth_tokens table"
      assert result =~ "Validation Rules"
      assert result =~ "Email must be unique"
    end

    test "displays observability section", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          telemetry_event: "[:kanban, :auth, :login]",
          metrics_to_track: "Login success rate, OAuth latency",
          logging_requirements: "Log all authentication attempts"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Observability"
      assert result =~ "Telemetry Event"
      assert result =~ "[:kanban, :auth, :login]"
      assert result =~ "Metrics to Track"
      assert result =~ "Login success rate, OAuth latency"
      assert result =~ "Logging Requirements"
      assert result =~ "Log all authentication attempts"
    end

    test "displays error handling section", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          error_user_message: "Authentication failed. Please try again.",
          error_on_failure: "Redirect to login page and show error message"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Error Handling"
      assert result =~ "User Message"
      assert result =~ "Authentication failed. Please try again."
      assert result =~ "On Failure"
      assert result =~ "Redirect to login page and show error message"
    end

    test "displays technology requirements", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          technology_requirements: ["Ueberauth", "Ueberauth.Strategy.Google", "HTTPoison"]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Technology Requirements"
      assert result =~ "Ueberauth"
      assert result =~ "Ueberauth.Strategy.Google"
      assert result =~ "HTTPoison"
    end

    test "displays required agent capabilities", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          required_capabilities: ["web_browsing", "code_execution", "file_operations"]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Required Agent Capabilities"
      assert result =~ "web_browsing"
      assert result =~ "code_execution"
      assert result =~ "file_operations"
    end

    test "displays dependencies section", %{board: board} do
      column = column_fixture(board)
      {:ok, dep1} = Tasks.create_task(column, %{"title" => "Dep 1"})
      {:ok, dep2} = Tasks.create_task(column, %{"title" => "Dep 2"})
      {:ok, dep3} = Tasks.create_task(column, %{"title" => "Dep 3"})

      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Test Task",
          "dependencies" => [dep1.identifier, dep2.identifier, dep3.identifier]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Dependencies"
      assert result =~ "Depends on tasks"
      assert result =~ "#{dep1.identifier}, #{dep2.identifier}, #{dep3.identifier}"
    end

    test "displays pitfalls section with yellow background", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          pitfalls: [
            "Don't store OAuth tokens in plain text",
            "Remember to refresh expired tokens"
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Pitfalls to Avoid"
      assert result =~ "bg-yellow-50"
      assert result =~ "Don&#39;t store OAuth tokens in plain text"
      assert result =~ "Remember to refresh expired tokens"
    end

    test "displays out of scope section with red background", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          out_of_scope: ["Multi-factor authentication", "Password reset functionality"]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Out of Scope"
      assert result =~ "bg-red-50"
      assert result =~ "Multi-factor authentication"
      assert result =~ "Password reset functionality"
    end

    test "displays actual vs estimated section for completed tasks", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: ~U[2024-01-15 15:00:00Z],
          complexity: :medium,
          estimated_files: "5",
          actual_complexity: :large,
          actual_files_changed: "8",
          time_spent_minutes: 240
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Actual vs Estimated"
      assert result =~ "bg-blue-50"
      assert result =~ "Actual Complexity"
      assert result =~ "Large"
      assert result =~ "Est"
      assert result =~ "Medium"
      assert result =~ "Actual Files Changed"
      assert result =~ "8"
      assert result =~ "5"
      assert result =~ "Time Spent"
      assert result =~ "240"
      assert result =~ "minutes"
    end

    test "displays review status section when needs_review is true", %{board: board} do
      reviewer = user_fixture(%{name: "Carol Reviewer"})
      column = column_fixture(board)
      reviewed_at = ~U[2024-01-15 14:00:00Z]

      task =
        task_fixture(column, %{
          needs_review: true,
          review_status: :approved,
          reviewed_by_id: reviewer.id,
          reviewed_at: reviewed_at,
          review_notes: "Looks good! Well implemented."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review Status"
      assert result =~ "bg-green-50"
      assert result =~ "Approved"
      assert result =~ "Reviewed by"
      assert result =~ "Carol Reviewer"
      assert result =~ "Reviewed at"
      assert result =~ "Review Notes"
      assert result =~ "Looks good! Well implemented."
    end

    test "displays review status with changes_requested styling", %{board: board} do
      reviewer = user_fixture(%{name: "Reviewer User"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          needs_review: true,
          review_status: :changes_requested,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z],
          review_notes: "Please add more tests"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review Status"
      assert result =~ "bg-orange-50"
      assert result =~ "Changes Requested"
      assert result =~ "Please add more tests"
    end

    test "displays completion section for completed tasks", %{board: board} do
      completer = user_fixture(%{name: "Dave Completer"})
      column = column_fixture(board)
      completed_at = ~U[2024-01-15 15:00:00Z]

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: completed_at,
          completed_by_id: completer.id,
          completed_by_agent: "Claude-3.5-Sonnet",
          completion_summary: "Implemented OAuth with Google and GitHub providers"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Completion"
      assert result =~ "bg-green-50"
      assert result =~ "Completed at"
      assert result =~ "Completed by"
      assert result =~ "Dave Completer"
      assert result =~ "Agent"
      assert result =~ "Claude-3.5-Sonnet"
      assert result =~ "Summary"
      assert result =~ "Implemented OAuth with Google and GitHub providers"
    end

    test "does not display creator info section when no creator data", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Creator Info"
    end

    test "does not display context section when all context fields are nil", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Context"
    end

    test "does not display key files section when key_files is empty", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Key Files"
    end

    test "does not display verification steps section when verification_steps is empty",
         %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Verification Steps"
    end

    test "does not display actual vs estimated section for non-completed tasks", %{
      board: board
    } do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :in_progress,
          actual_complexity: :large,
          actual_files_changed: "8"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Actual vs Estimated"
    end

    test "does not display completion section for non-completed tasks", %{board: board} do
      completer = user_fixture(%{name: "Dave Completer"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :in_progress,
          completed_by_id: completer.id,
          completion_summary: "Some summary"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Completion"
    end

    test "displays estimated_files in header grid", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{estimated_files: "7"})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Estimated Files"
      assert result =~ "7"
    end

    test "displays status badge for all status types", %{board: board} do
      column = column_fixture(board)

      for status <- [:open, :in_progress, :completed, :blocked] do
        attrs =
          if status == :completed do
            %{status: status, completed_at: ~U[2024-01-15 15:00:00Z]}
          else
            %{status: status}
          end

        task = task_fixture(column, attrs)

        result =
          render_component(KanbanWeb.TaskLive.ViewComponent,
            id: "test-view-#{status}",
            task_id: task.id,
            field_visibility: all_fields_visible()
          )

        status_label =
          case status do
            :open -> "Open"
            :in_progress -> "In Progress"
            :completed -> "Completed"
            :blocked -> "Blocked"
          end

        assert result =~ status_label
      end
    end

    test "displays complexity badge for all complexity types", %{board: board} do
      column = column_fixture(board)

      for complexity <- [:small, :medium, :large] do
        task = task_fixture(column, %{complexity: complexity})

        result =
          render_component(KanbanWeb.TaskLive.ViewComponent,
            id: "test-view-#{complexity}",
            task_id: task.id,
            field_visibility: all_fields_visible()
          )

        complexity_label =
          case complexity do
            :small -> "Small"
            :medium -> "Medium"
            :large -> "Large"
          end

        assert result =~ complexity_label
      end
    end

    test "displays security considerations section with purple background", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          security_considerations: [
            "Hash all passwords with bcrypt",
            "Never log sensitive data",
            "Validate all user input"
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Security Considerations"
      assert result =~ "bg-purple-50"
      assert result =~ "Hash all passwords with bcrypt"
      assert result =~ "Never log sensitive data"
      assert result =~ "Validate all user input"
    end

    test "does not display security considerations when field_visibility is false", %{
      board: board
    } do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          security_considerations: ["Hash passwords"]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: %{"security_considerations" => false}
        )

      refute result =~ "Security Considerations"
      refute result =~ "Hash passwords"
    end

    test "does not display security considerations when empty", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{security_considerations: []})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Security Considerations"
    end

    test "displays testing strategy section with cyan background and all test types", %{
      board: board
    } do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          testing_strategy: %{
            "unit_tests" => ["Test authentication module", "Test validation functions"],
            "integration_tests" => ["Test end-to-end login flow"],
            "manual_tests" => ["Verify password reset email"]
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Testing Strategy"
      assert result =~ "bg-cyan-50"
      assert result =~ "Unit Tests"
      assert result =~ "Test authentication module"
      assert result =~ "Test validation functions"
      assert result =~ "Integration Tests"
      assert result =~ "Test end-to-end login flow"
      assert result =~ "Manual Tests"
      assert result =~ "Verify password reset email"
    end

    test "displays testing strategy with only unit tests", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          testing_strategy: %{
            "unit_tests" => ["Test module A", "Test module B"]
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Testing Strategy"
      assert result =~ "Unit Tests"
      assert result =~ "Test module A"
      assert result =~ "Test module B"
      refute result =~ "Integration Tests"
      refute result =~ "Manual Tests"
    end

    test "does not display testing strategy when field_visibility is false", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          testing_strategy: %{"unit_tests" => ["Test something"]}
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: %{"testing_strategy" => false}
        )

      refute result =~ "Testing Strategy"
      refute result =~ "Test something"
    end

    test "does not display testing strategy when empty", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{testing_strategy: %{}})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Testing Strategy"
    end

    test "displays integration points section with indigo background and all point types", %{
      board: board
    } do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          integration_points: %{
            "telemetry_events" => ["[:kanban, :task, :created]", "[:kanban, :task, :updated]"],
            "pubsub_broadcasts" => ["board:updated", "task:moved"],
            "phoenix_channels" => ["task:123"],
            "external_apis" => ["https://api.stripe.com", "https://api.sendgrid.com"]
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Integration Points"
      assert result =~ "bg-indigo-50"
      assert result =~ "Telemetry Events"
      assert result =~ "[:kanban, :task, :created]"
      assert result =~ "[:kanban, :task, :updated]"
      assert result =~ "PubSub Broadcasts"
      assert result =~ "board:updated"
      assert result =~ "task:moved"
      assert result =~ "Phoenix Channels"
      assert result =~ "task:123"
      assert result =~ "External APIs"
      assert result =~ "https://api.stripe.com"
      assert result =~ "https://api.sendgrid.com"
    end

    test "displays integration points with only telemetry events", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          integration_points: %{
            "telemetry_events" => ["[:kanban, :auth, :login]"]
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Integration Points"
      assert result =~ "Telemetry Events"
      assert result =~ "[:kanban, :auth, :login]"
      refute result =~ "PubSub Broadcasts"
      refute result =~ "Phoenix Channels"
      refute result =~ "External APIs"
    end

    test "does not display integration points when field_visibility is false", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          integration_points: %{"telemetry_events" => ["[:kanban, :event]"]}
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: %{"integration_points" => false}
        )

      refute result =~ "Integration Points"
      refute result =~ "[:kanban, :event]"
    end

    test "does not display integration points when empty", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{integration_points: %{}})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Integration Points"
    end

    test "displays all three AI context fields together", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          security_considerations: ["Use HTTPS", "Hash passwords"],
          testing_strategy: %{
            "unit_tests" => ["Test auth module"],
            "integration_tests" => ["Test login flow"]
          },
          integration_points: %{
            "telemetry_events" => ["[:app, :auth, :success]"],
            "pubsub_broadcasts" => ["user:authenticated"]
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Security Considerations"
      assert result =~ "Use HTTPS"
      assert result =~ "Testing Strategy"
      assert result =~ "Test auth module"
      assert result =~ "Integration Points"
      assert result =~ "[:app, :auth, :success]"
    end

    test "displays assigned user email when name is not present", %{board: board} do
      user = user_fixture(%{name: nil, email: "testuser@example.com"})
      column = column_fixture(board)
      task = task_fixture(column, %{assigned_to_id: user.id})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Assigned To"
      assert result =~ "testuser@example.com"
    end

    test "displays child tasks table for goal type with children", %{board: board} do
      column = column_fixture(board)

      {:ok, %{goal: goal}} =
        Tasks.create_goal_with_tasks(
          column,
          %{"title" => "Parent Goal"},
          [
            %{"title" => "Child Task 1", "type" => "work"},
            %{"title" => "Child Task 2", "type" => "defect"}
          ]
        )

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: goal.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Child Tasks"
      assert result =~ "Child Task 1"
      assert result =~ "Child Task 2"
    end

    test "displays review status with pending styling", %{board: board} do
      reviewer = user_fixture(%{name: "Pending Reviewer"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          needs_review: true,
          review_status: :pending,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z],
          review_notes: "Waiting for review"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review Status"
      assert result =~ "bg-yellow-50"
      assert result =~ "Pending"
      assert result =~ "Waiting for review"
    end

    test "displays review status with rejected styling", %{board: board} do
      reviewer = user_fixture(%{name: "Rejecting Reviewer"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          needs_review: true,
          review_status: :rejected,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z],
          review_notes: "Not acceptable"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review Status"
      assert result =~ "bg-red-50"
      assert result =~ "Rejected"
      assert result =~ "Not acceptable"
    end

    test "displays acceptance criteria when visible and present", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          acceptance_criteria: "User can log in successfully\nPassword is validated"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Acceptance Criteria"
      assert result =~ "User can log in successfully"
      assert result =~ "Password is validated"
    end

    test "does not display acceptance criteria when field_visibility is false", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          acceptance_criteria: "Some criteria"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: %{"acceptance_criteria" => false}
        )

      refute result =~ "Acceptance Criteria"
      refute result =~ "Some criteria"
    end
  end
end
