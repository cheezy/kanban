defmodule KanbanWeb.TaskLive.ViewComponentTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.AccountsFixtures

  alias Kanban.Repo
  alias Kanban.Schemas.Task.BehaviourTestRow
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
      "integration_points" => true,
      "technical_details" => true,
      "behaviour_test_matrix" => true
    }
  end

  defp full_matrix_rows do
    BehaviourTestRow.categories()
    |> Enum.with_index()
    |> Enum.map(fn {category, index} ->
      %{
        "category" => category,
        "behaviour" => "behaviour for #{category}",
        "test_name" => "test for #{category}",
        "type" => "unit",
        "status" => "planned",
        "position" => index
      }
    end)
  end

  describe "ViewComponent" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      %{user: user, board: board, column: column, task: task}
    end

    test "renders the behaviour_test_matrix rows when the board enables the field",
         %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{behaviour_test_matrix: full_matrix_rows()})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Behaviour/Test Matrix"

      for category <- BehaviourTestRow.categories() do
        assert result =~ "behaviour for #{category}"
        assert result =~ "test for #{category}"
      end
    end

    test "hides the behaviour_test_matrix section when the board disables the field",
         %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{behaviour_test_matrix: full_matrix_rows()})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: Map.put(all_fields_visible(), "behaviour_test_matrix", false)
        )

      refute result =~ "Behaviour/Test Matrix"
      refute result =~ "behaviour for Happy path"
    end

    test "shows a waived row's reason instead of a test name", %{board: board} do
      column = column_fixture(board)

      rows =
        Enum.map(full_matrix_rows(), fn
          %{"category" => "Concurrency"} = row ->
            row
            |> Map.drop(["test_name"])
            |> Map.merge(%{"status" => "not_applicable", "na_reason" => "single-process path"})

          row ->
            row
        end)

      task = task_fixture(column, %{behaviour_test_matrix: rows})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "single-process path"
      assert result =~ "Not applicable"
      refute result =~ "test for Concurrency"
    end

    test "escapes markup in agent-supplied row text rather than executing it (W1947)", %{
      board: board
    } do
      column = column_fixture(board)

      rows =
        Enum.map(full_matrix_rows(), fn
          %{"category" => "Concurrency"} = row ->
            row
            |> Map.drop(["test_name"])
            |> Map.merge(%{
              "status" => "not_applicable",
              "na_reason" => "<img src=x onerror=alert(1)>"
            })

          %{"category" => "Happy path"} = row ->
            Map.merge(row, %{
              "behaviour" => "<script>alert('xss')</script>",
              "test_name" => "<b>bold</b>"
            })

          row ->
            row
        end)

      task = task_fixture(column, %{behaviour_test_matrix: rows})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      # Row text is attacker-controlled at the API boundary, so the render-side
      # escaping — not the authoring convention — is the control that matters.
      refute result =~ "<script>alert('xss')</script>"
      refute result =~ "<img src=x onerror=alert(1)>"
      refute result =~ "<b>bold</b>"

      assert result =~ "&lt;script&gt;"
      assert result =~ "&lt;img src=x onerror=alert(1)&gt;"
      assert result =~ "&lt;b&gt;bold&lt;/b&gt;"
    end

    test "omits the section entirely when the task has no matrix rows", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Behaviour/Test Matrix"
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

      # New design renders description as plain paragraph below the
      # title — no "Description" label.
      assert result =~ "This is a test description"
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

    test "shows the Technical details section when technical_details is non-empty and visible",
         %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{technical_details: %{"approach" => "use Ecto.Multi"}})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Technical details"
      assert result =~ "approach"
      assert result =~ "use Ecto.Multi"
    end

    test "hides the Technical details section when technical_details is empty", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{technical_details: %{}})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Technical details"
    end

    test "hides the Technical details section when the field is not visible", %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{technical_details: %{"approach" => "use Ecto.Multi"}})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: Map.put(all_fields_visible(), "technical_details", false)
        )

      refute result =~ "Technical details"
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

      # New design uses a TypeIcon (hero-document-text for :work) inside
      # the inline detail band rather than a colored text pill.
      assert result =~ "hero-document-text"
      assert result =~ "data-task-detail-band"
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

      assert result =~ "hero-bug-ant"
      assert result =~ "var(--st-blocked)"
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

      assert result =~ "hero-flag"
      assert result =~ "var(--stride-violet)"
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
      assert result =~ "var(--pri-low)"
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
      assert result =~ "var(--pri-medium)"
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
      assert result =~ "var(--pri-high)"
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
      assert result =~ "var(--pri-critical)"
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

      # The new metadata grid uses "Author" as the label (matches design).
      assert result =~ "Author"
      assert result =~ "John Doe"
    end

    test "displays 'Unassigned' when no user assigned", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      # New metadata grid omits the Author row entirely when both
      # assigned_to and created_by are nil — so the absence of an Author
      # label is the contract.
      refute result =~ ~r/>\s*Author\s*</
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
      assert result =~ "var(--st-done)"
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
      assert result =~ "var(--st-doing)"
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
      %TaskComment{task_id: task.id}
      |> TaskComment.changeset(%{
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
      %TaskComment{task_id: task.id}
      |> TaskComment.changeset(%{
        content: "First comment",
        inserted_at: ~U[2024-01-15 10:00:00Z]
      })
      |> Repo.insert!()

      %TaskComment{task_id: task.id}
      |> TaskComment.changeset(%{
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
      %TaskComment{task_id: task.id}
      |> TaskComment.changeset(%{
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
      assert result =~ "var(--stride-orange)"
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
      assert result =~ "var(--stride-violet)"
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
      assert result =~ "var(--stride-violet)"
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
      assert result =~ "var(--stride-violet)"
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

      # New design surfaces the author in the right-rail Author MetaItem
      # (when assigned_to OR created_by is set) rather than a labeled
      # "Created by" section.
      assert result =~ "Author"
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

      # The new right rail surfaces an Author row from the user even when
      # created_by_agent is set; the agent name itself is captured in
      # history rather than a dedicated label.
      assert result =~ "Author"
      assert result =~ "Bob User"
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

      # New design moved the claim timestamp into the right-rail "Claimed"
      # MetaItem; the legacy "Claim expires" callout was retired (the
      # claim window is now tracked through history + the claim badge).
      assert result =~ "Claimed"
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

      # The Context block is now three stacked Block components in the
      # left main column (matching the design's pane variant).
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

      assert result =~ "Key files"
      assert result =~ "lib/kanban/auth.ex"
      assert result =~ "Main auth module"
      assert result =~ "lib/kanban_web/controllers/auth_controller.ex"
      assert result =~ "OAuth controller"

      # W1391: long monospace file paths must break rather than clip past the
      # main pane (which has overflow: hidden) on a 375px viewport.
      assert result =~ "overflow-wrap: anywhere"
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

      assert result =~ "Verification steps"
      # The new design renders step text inline with a `→ expected result`
      # subdued caption; the step_type pill ("command" / "manual") was
      # dropped because the design treats every step as a list item with
      # the same affordance.
      assert result =~ "mix test"
      assert result =~ "All tests pass"
      assert result =~ "Log in with OAuth"
      assert result =~ "User successfully authenticated"

      # W1391: long monospace verification commands must break within the
      # grid column rather than overflow it at 375px.
      assert result =~ "overflow-wrap: anywhere"
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

      # The legacy "Implementation Guidance" wrapper was replaced with
      # three side-by-side SectionCards.
      assert result =~ "Patterns to follow"
      assert result =~ "Follow existing authentication patterns"
      assert result =~ "Database changes"
      assert result =~ "Add oauth_tokens table"
      assert result =~ "Validation rules"
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
      # New design uses condensed sub-labels (Telemetry / Metrics / Logging)
      # inside a single SectionCard. Match the labels as standalone words.
      assert result =~ ~r/>\s*Telemetry\s*</
      assert result =~ "[:kanban, :auth, :login]"
      assert result =~ ~r/>\s*Metrics\s*</
      assert result =~ "Login success rate, OAuth latency"
      assert result =~ ~r/>\s*Logging\s*</
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

      assert result =~ "Error handling"
      # New design renders the user message text directly; "On failure"
      # becomes an inline subdued label.
      assert result =~ "Authentication failed. Please try again."
      assert result =~ "On failure"
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

      assert result =~ "Technology requirements"
      assert result =~ "Ueberauth"
      assert result =~ "Ueberauth.Strategy.Google"
      assert result =~ "HTTPoison"
    end

    test "displays required agent capabilities in the right rail", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          required_capabilities: ["web_browsing", "git", "file_operations"]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      # New design surfaces required capabilities in the right rail as
      # the "Capabilities" MetaItem with violet pills.
      assert result =~ "Capabilities"
      assert result =~ "web_browsing"
      assert result =~ "git"
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

      assert result =~ "Pitfalls"
      # SectionCard tone={:warn} shifts the title color to the blocked token.
      assert result =~ "color: var(--st-blocked)"
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

      assert result =~ "Out of scope"
      # SectionCard tone={:muted} shifts the title color to ink-3.
      assert result =~ "color: var(--ink-3)"
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
      assert result =~ "bg-[var(--st-ready-soft)]"
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
      assert result =~ "bg-[var(--st-done-soft)]"
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
      assert result =~ "bg-[var(--stride-orange-soft)]"
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
      assert result =~ "bg-[var(--st-done-soft)]"
      assert result =~ "Completed at"
      assert result =~ "Completed by"
      assert result =~ "Dave Completer"
      assert result =~ "Agent"
      assert result =~ "Claude-3.5-Sonnet"
      assert result =~ "Summary"
      assert result =~ "Implemented OAuth with Google and GitHub providers"
    end

    test "displays completion notes in the completion section (W1963)", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: ~U[2024-01-15 15:00:00Z],
          completion_summary: "Short one-liner",
          completion_notes: "The longer narrative the agent recorded."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Short one-liner"
      assert result =~ "Completion notes"
      assert result =~ "The longer narrative the agent recorded."

      # Summary reads first, notes second. elem/2 raises on :nomatch rather than
      # letting the comparison pass vacuously — :binary.match/2 returns the atom
      # :nomatch when absent, and atoms sort before tuples in Erlang term order.
      summary_at = result |> :binary.match("Short one-liner") |> elem(0)
      notes_at = result |> :binary.match("The longer narrative the agent recorded.") |> elem(0)

      assert summary_at < notes_at
    end

    test "omits the notes block when completion_notes is nil (W1963)", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: ~U[2024-01-15 15:00:00Z],
          completion_summary: "Only a summary"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Summary"
      refute result =~ "Completion notes"
    end

    test "completion notes preserve line breaks and wrap long unbroken strings (W1963)", %{
      board: board
    } do
      column = column_fixture(board)

      notes =
        "First paragraph.\n\nSecond paragraph.\nlib/kanban_web/live/task_live/view_component.ex"

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: ~U[2024-01-15 15:00:00Z],
          completion_notes: notes
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "whitespace-pre-wrap break-words"
      assert result =~ "First paragraph."
      assert result =~ "Second paragraph."
      assert result =~ "lib/kanban_web/live/task_live/view_component.ex"
    end

    test "completion notes render markup-like text literally rather than as markup (W1963)", %{
      board: board
    } do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :completed,
          completed_at: ~U[2024-01-15 15:00:00Z],
          completion_notes: "Refused row 3 <script>alert('x')</script> & <b>bold</b>"
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "<script>alert('x')</script>"
      assert result =~ "&lt;script&gt;"
      assert result =~ "&lt;b&gt;bold&lt;/b&gt;"
    end

    test "displays the completion section for a review-bound task that never reached :completed (W1963)",
         %{board: board} do
      reviewer = user_fixture(%{name: "Reviewer User"})
      completer = user_fixture(%{name: "Dave Completer"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :in_progress,
          needs_review: true,
          review_status: :changes_requested,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z],
          completed_at: ~U[2024-01-15 13:00:00Z],
          completed_by_id: completer.id,
          completed_by_agent: "Claude Opus 5",
          completion_summary: "Ready for review",
          completion_notes: "What the agent actually did."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      # The whole section — not just the notes — is now visible during Review.
      # Assert on the section head rather than the panel's bg token: the Review
      # Status panel reuses --st-done-soft, so that class cannot tell them apart.
      assert result =~ "<span>Completion</span>"
      assert result =~ "Completed by"
      assert result =~ "Dave Completer"
      assert result =~ "Claude Opus 5"
      assert result =~ "Ready for review"
      assert result =~ "Completion notes"
      assert result =~ "What the agent actually did."
      # It coexists with the review sections rather than replacing them.
      assert result =~ "Review Status"
    end

    test "displays the completion section for a review-bound task carrying only completion_notes (W1963)",
         %{board: board} do
      reviewer = user_fixture(%{name: "Reviewer User"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :in_progress,
          needs_review: true,
          review_status: :approved,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z],
          completion_notes: "Notes are the only completion field set."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "<span>Completion</span>"
      assert result =~ "Completion notes"
      assert result =~ "Notes are the only completion field set."
    end

    test "does not display the completion section for a review-or-done task with no completion fields (W1963)",
         %{board: board} do
      reviewer = user_fixture(%{name: "Reviewer User"})
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :in_progress,
          needs_review: true,
          review_status: :approved,
          reviewed_by_id: reviewer.id,
          reviewed_at: ~U[2024-01-15 14:00:00Z]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "<span>Completion</span>"
      refute result =~ "Completion notes"
    end

    test "does not display the completion section for an open task carrying completion fields (W1963)",
         %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          status: :open,
          completion_summary: "Somehow set",
          completion_notes: "Should stay hidden."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "<span>Completion</span>"
      refute result =~ "Should stay hidden."
    end

    test "displays review_report section via ReviewReportPanel when review_report is present",
         %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          review_report: "## Review\n\nAll acceptance criteria met.\nNo issues found."
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review report"
      assert result =~ ~s(data-review-report-panel="fallback")
      assert result =~ "All acceptance criteria met."
      assert result =~ "No issues found."
    end

    test "displays review_report section via ReviewReportPanel when reviewer_result is present",
         %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          reviewer_result: %{
            "dispatched" => true,
            "summary" => "Reviewed all acceptance criteria; approved.",
            "issues" => []
          }
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Review report"
      assert result =~ ~s(data-review-report-panel="structured")
      # The reviewer's prose summary now renders inside the panel (D62) so a
      # completed/approved review is not reduced to a bare issue list.
      assert result =~ "data-review-report-summary"
      assert result =~ "Reviewed all acceptance criteria; approved."
    end

    test "does not display review_report section when review_report is nil", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Review report"
    end

    test "does not display review_report section when review_report is empty string",
         %{board: board} do
      column = column_fixture(board)
      task = task_fixture(column, %{review_report: ""})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Review report"
    end

    test "displays workflow_steps section when workflow_steps is non-empty", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          workflow_steps: [
            %{"name" => "before_doing", "status" => "success", "duration_ms" => 120},
            %{"name" => "after_doing", "exit_code" => 0, "duration_ms" => 5400}
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Workflow Steps"
      assert result =~ "bg-[var(--stride-violet-soft)]"
      assert result =~ "Before Doing"
      assert result =~ "After Doing"
      assert result =~ "120 ms"
      assert result =~ "5400 ms"
    end

    test "hides workflow_steps section when workflow_steps is empty", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Workflow Steps"
    end

    test "renders workflow step with skipped status and reason", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          workflow_steps: [
            %{
              "name" => "before_review",
              "skipped" => true,
              "reason" => "needs_review is false"
            }
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Before Review"
      assert result =~ "Skipped"
      assert result =~ "Reason"
      assert result =~ "needs_review is false"
    end

    test "renders workflow step with only name (no duration, no status)", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{workflow_steps: [%{"name" => "plan"}]})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "plan"
      assert result =~ "Dispatched"
    end

    test "renders workflow step with dispatched=false", %{board: board} do
      column = column_fixture(board)

      task =
        task_fixture(column, %{
          workflow_steps: [%{"name" => "after_review", "dispatched" => false}]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "After Review"
      assert result =~ "Not dispatched"
    end

    test "renders workflow step with non-ASCII name and long reason", %{board: board} do
      column = column_fixture(board)
      long_reason = String.duplicate("very long reason text ", 20)

      task =
        task_fixture(column, %{
          workflow_steps: [
            %{
              "name" => "レビュー前フック",
              "skipped" => true,
              "reason" => long_reason
            }
          ]
        })

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "レビュー前フック"
      assert result =~ String.trim(long_reason)
      assert result =~ "break-words"
    end

    test "does not display creator info section when no creator data", %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Creator"
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

      refute result =~ "Key files"
    end

    test "does not display verification steps section when verification_steps is empty",
         %{task: task} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      refute result =~ "Verification steps"
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

      # New design renders estimated_files as a right-rail MetaItem.
      assert result =~ "Estimated files"
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
            :in_progress -> "Doing"
            :completed -> "Done"
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

      assert result =~ "Security considerations"
      # SectionCard at default tone renders the surface token.
      assert result =~ "background: var(--surface)"
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

      refute result =~ "Security considerations"
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

      refute result =~ "Security considerations"
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
      assert result =~ "bg-[var(--st-ready-soft)]"
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
      assert result =~ "bg-[var(--stride-violet-soft)]"
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

      assert result =~ "Security considerations"
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

      assert result =~ "Author"
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
      assert result =~ "bg-[var(--st-doing-soft)]"
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
      assert result =~ "bg-[var(--st-blocked-soft)]"
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

      # New design uses sentence-case "Acceptance criteria" and emits a
      # data-acceptance-checklist marker on the rendered checklist.
      assert result =~ "Acceptance criteria"
      assert result =~ "data-acceptance-checklist"
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

  describe "board scoping and not-found state" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      %{user: user, board: board, column: column}
    end

    test "renders the not-found state when the task does not exist", %{board: board} do
      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: -1,
          board_id: board.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Task Not Found"
      assert result =~ "hero-exclamation-triangle"
      assert result =~ "This task may have been deleted"
    end

    test "refuses to render a task that belongs to a different board", %{board: board} do
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board)
      foreign_task = task_fixture(other_column, %{title: "Foreign Task"})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: foreign_task.id,
          board_id: board.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Task Not Found"
      refute result =~ "Foreign Task"
    end
  end

  describe "metadata panel branches" do
    setup do
      user = user_fixture()
      board = board_fixture(user, %{name: "Render Branch Board"})
      column = column_fixture(board)

      %{user: user, board: board, column: column}
    end

    test "shows only the priority word when complexity is unset", %{column: column} do
      task = task_fixture(column, %{priority: :high, complexity: nil})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "High"
      refute result =~ "High ·"
    end

    test "shows the human task indicator when human_task is set", %{column: column} do
      task = task_fixture(column, %{human_task: true})

      result =
        render_component(KanbanWeb.TaskLive.ViewComponent,
          id: "test-view",
          task_id: task.id,
          field_visibility: all_fields_visible()
        )

      assert result =~ "Human task"
      assert result =~ "Yes"
    end

    # The component's own loader does not preload :parent or column: :board,
    # so these render branches are exercised by driving render/1 directly with
    # a deeply-loaded task — the same path a caller with a preloaded task hits.
    test "shows the parent goal when the parent association is loaded", %{column: column} do
      goal = task_fixture(column, %{type: :goal, title: "Epic Goal"})
      child = task_fixture(column, %{parent_id: goal.id})

      task =
        child.id
        |> Tasks.get_task_for_view()
        |> Repo.preload(:parent)

      result =
        render_component(&KanbanWeb.TaskLive.ViewComponent.render/1, %{
          task: task,
          board_id: nil,
          can_modify: false,
          field_visibility: all_fields_visible()
        })

      assert result =~ "Goal"
      assert result =~ "hero-flag"
      assert result =~ goal.identifier
      assert result =~ "Epic Goal"
    end

    test "shows the board name when column.board is loaded", %{column: column} do
      task_record = task_fixture(column)

      task =
        task_record.id
        |> Tasks.get_task_for_view()
        |> Repo.preload(column: :board)

      result =
        render_component(&KanbanWeb.TaskLive.ViewComponent.render/1, %{
          task: task,
          board_id: nil,
          can_modify: false,
          field_visibility: all_fields_visible()
        })

      assert result =~ "Board"
      assert result =~ "Render Branch Board"
    end
  end

  describe "explorer-result section visibility gate (W1960)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      reviewer = user_fixture()

      %{user: user, board: board, column: column, reviewer: reviewer}
    end

    # The schema requires reviewed_by_id and reviewed_at whenever review_status
    # is anything other than :pending, and completed_at whenever status is
    # :completed — so these fixtures must supply them.
    defp approved_review(reviewer) do
      %{
        needs_review: true,
        review_status: :approved,
        reviewed_by_id: reviewer.id,
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    end

    defp completed do
      %{
        status: :completed,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    end

    # The explorer_result summary doubles as the content-level probe. Asserting
    # only on a heading would not prove the component actually received the map.
    @explorer_result %{
      "dispatched" => true,
      "summary" => "Explored the three key_files and identified the pattern to mirror.",
      "duration_ms" => 12_500
    }

    defp render_task(task) do
      render_component(KanbanWeb.TaskLive.ViewComponent,
        id: "test-view",
        task_id: task.id,
        field_visibility: all_fields_visible()
      )
    end

    # Both spellings are checked deliberately: the SectionHead title is
    # "Explorer result" (sibling convention) while the component's own h4 is
    # "Explorer Result". Refuting only one would let the other leak through.
    defp assert_explorer_section(result) do
      assert result =~ "Explorer result"
      assert result =~ "Explorer Result"
      assert result =~ "Explored the three key_files"
    end

    defp refute_explorer_section(result) do
      refute result =~ "Explorer result"
      refute result =~ "Explorer Result"
      refute result =~ "Explored the three key_files"
    end

    test "renders the section for a task with review_status set",
         %{column: column, reviewer: reviewer} do
      task =
        reviewer
        |> approved_review()
        |> Map.put(:explorer_result, @explorer_result)
        |> then(&task_fixture(column, &1))

      assert_explorer_section(render_task(task))
    end

    test "renders the section for a task with review_status set but still in progress",
         %{column: column} do
      task =
        task_fixture(column, %{
          explorer_result: @explorer_result,
          status: :in_progress,
          needs_review: true,
          review_status: :pending
        })

      assert_explorer_section(render_task(task))
    end

    test "renders the section for a completed task", %{column: column} do
      task =
        task_fixture(column, Map.merge(completed(), %{explorer_result: @explorer_result}))

      assert_explorer_section(render_task(task))
    end

    test "does not render the section for an open task with a populated explorer_result",
         %{column: column} do
      task =
        task_fixture(column, %{
          explorer_result: @explorer_result,
          status: :open,
          review_status: nil
        })

      refute_explorer_section(render_task(task))
    end

    test "does not render the section for an in-progress task with review_status nil",
         %{column: column} do
      task =
        task_fixture(column, %{
          explorer_result: @explorer_result,
          status: :in_progress,
          review_status: nil
        })

      refute_explorer_section(render_task(task))
    end

    test "does not render the section when explorer_result is nil", %{column: column} do
      task =
        task_fixture(column, Map.merge(completed(), %{explorer_result: nil}))

      refute_explorer_section(render_task(task))
    end

    test "does not render the section when explorer_result is an empty map",
         %{column: column, reviewer: reviewer} do
      task =
        task_fixture(
          column,
          approved_review(reviewer) |> Map.merge(completed()) |> Map.put(:explorer_result, %{})
        )

      refute_explorer_section(render_task(task))
    end

    test "renders the skip shape with its translated reason label", %{column: column} do
      task =
        task_fixture(
          column,
          Map.merge(completed(), %{
            explorer_result: %{
              "dispatched" => false,
              "reason" => "small_task_0_1_key_files",
              "summary" => "Read the single key file directly; no dispatch was warranted."
            }
          })
        )

      result = render_task(task)

      assert result =~ "Explorer result"
      assert result =~ "Not dispatched"
      assert result =~ "Small task (0-1 key files)"
      refute result =~ "small_task_0_1_key_files"
    end

    # Locale note (W1961): render_component/2 renders in the TEST process, so
    # Gettext.put_locale/2 does reach it. That is NOT true of a live/2 test,
    # where the LiveView runs in its own process and the locale must arrive
    # through the session — see the session-based test in
    # test/kanban_web/live/metrics_live/workspace_test.exs. Both the SectionHead
    # title and the component's own labels are exercised here in one render.
    test "renders the section title and skip-reason label translated in every locale",
         %{column: column} do
      task =
        task_fixture(
          column,
          Map.merge(completed(), %{
            explorer_result: %{
              "dispatched" => false,
              "reason" => "small_task_0_1_key_files",
              "summary" => "Read the single key file directly."
            }
          })
        )

      expected = [
        {"de", "Explorer-Ergebnis", "Kleine Aufgabe (0–1 wichtige Dateien)"},
        {"es", "Resultado del explorador", "Tarea pequeña (0-1 archivos clave)"},
        {"fr", "Résultat de l&#39;explorateur", "Petite tâche (0-1 fichiers clés)"},
        {"ja", "エクスプローラー結果", "小さなタスク (キーファイル 0〜1 件)"},
        {"pt", "Resultado do explorador", "Tarefa pequena (0-1 arquivos principais)"},
        {"zh", "探索器结果", "小任务（0-1 个关键文件）"}
      ]

      original = Gettext.get_locale(KanbanWeb.Gettext)

      try do
        for {locale, title, reason_label} <- expected do
          Gettext.put_locale(KanbanWeb.Gettext, locale)
          result = render_task(task)

          assert result =~ title, "#{locale} did not render the translated section title"

          assert result =~ reason_label,
                 "#{locale} did not render the translated skip-reason label"

          refute result =~ "Explorer Result",
                 "#{locale} leaked the untranslated English heading"

          refute result =~ "Small task (0-1 key files)",
                 "#{locale} leaked the untranslated English skip-reason label"
        end
      after
        Gettext.put_locale(KanbanWeb.Gettext, original)
      end
    end

    test "renders the English source strings under the en locale", %{column: column} do
      task =
        task_fixture(
          column,
          Map.merge(completed(), %{
            explorer_result: %{
              "dispatched" => false,
              "reason" => "trivial_change_docs_only",
              "summary" => "Docs-only change."
            }
          })
        )

      original = Gettext.get_locale(KanbanWeb.Gettext)

      try do
        Gettext.put_locale(KanbanWeb.Gettext, "en")
        result = render_task(task)

        # English msgstr values are intentionally empty so gettext falls back to
        # the msgid — the locale-completeness guard exempts en for this reason.
        assert result =~ "Explorer Result"
        assert result =~ "Trivial change (docs only)"
      after
        Gettext.put_locale(KanbanWeb.Gettext, original)
      end
    end

    test "renders alongside the review report and workflow steps without disturbing order",
         %{column: column} do
      task =
        task_fixture(
          column,
          Map.merge(completed(), %{
            explorer_result: @explorer_result,
            reviewer_result: %{
              "dispatched" => true,
              "summary" => "Reviewed all acceptance criteria; approved.",
              "issues" => []
            },
            workflow_steps: [
              %{"name" => "explorer", "dispatched" => true, "duration_ms" => 12_500}
            ]
          })
        )

      result = render_task(task)

      assert result =~ "Review report"
      assert result =~ "Explorer result"
      assert result =~ "Workflow steps"

      review_at = :binary.match(result, "Review report") |> elem(0)
      explorer_at = :binary.match(result, "Explorer result") |> elem(0)
      workflow_at = :binary.match(result, "Workflow steps") |> elem(0)

      assert review_at < explorer_at,
             "the explorer section must follow the review report"

      assert explorer_at < workflow_at,
             "the explorer section must precede workflow steps"
    end
  end

  describe "changed-files diff panel (W1965)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      reviewer = user_fixture()

      %{user: user, board: board, column: column, reviewer: reviewer}
    end

    @changed_files [
      %{"path" => "lib/foo.ex", "diff" => "@@ -1 +1 @@\n-old foo\n+new foo"},
      %{"path" => "test/foo_test.exs", "diff" => "@@ -1 +1 @@\n+added assertion"}
    ]

    # actual_files_changed is deliberately left nil: the "Actual vs estimated"
    # section renders it verbatim, which would make a `refute html =~ path`
    # assertion pass or fail for the wrong reason.
    defp changed_files_task(column, attrs) do
      task_fixture(column, Map.merge(%{changed_files: @changed_files}, attrs))
    end

    defp render_changed_files_task(task) do
      render_component(KanbanWeb.TaskLive.ViewComponent,
        id: "test-view",
        task_id: task.id,
        field_visibility: all_fields_visible()
      )
    end

    # Direct update/handle_event unit harness — render_component cannot dispatch
    # events to a live_component, and this is the convention the board and task
    # form-component tests already use.
    defp build_view_socket(task_id, extra \\ %{}) do
      base = %{%Phoenix.LiveView.Socket{} | assigns: %{flash: %{}, __changed__: %{}}}

      assigns =
        Map.merge(
          %{id: "test-view", task_id: task_id, field_visibility: all_fields_visible()},
          extra
        )

      {:ok, socket} = KanbanWeb.TaskLive.ViewComponent.update(assigns, base)
      socket
    end

    defp select_file(socket, path) do
      {:noreply, socket} =
        KanbanWeb.TaskLive.ViewComponent.handle_event(
          "select_changed_file",
          %{"path" => path},
          socket
        )

      socket
    end

    test "renders the section and every changed file for a completed task", %{column: column} do
      task = changed_files_task(column, completed())

      html = render_changed_files_task(task)

      assert html =~ "Changed files"
      assert html =~ "data-review-diff-panel"
      assert html =~ "lib/foo.ex"
      assert html =~ "test/foo_test.exs"
    end

    test "renders the section for a task in review that never reached :completed",
         %{column: column, reviewer: reviewer} do
      task = changed_files_task(column, approved_review(reviewer))

      html = render_changed_files_task(task)

      assert html =~ "Changed files"
      assert html =~ "data-review-diff-panel"
    end

    test "omits the section for an :open task carrying changed files", %{column: column} do
      task = changed_files_task(column, %{status: :open})

      html = render_changed_files_task(task)

      refute html =~ "data-review-diff-panel"
      refute html =~ "lib/foo.ex"
    end

    test "omits the section for an :in_progress task with review_status nil", %{column: column} do
      task = changed_files_task(column, %{status: :in_progress, review_status: nil})

      html = render_changed_files_task(task)

      refute html =~ "data-review-diff-panel"
    end

    test "omits the section for a completed task whose changed_files is empty",
         %{column: column} do
      task = task_fixture(column, Map.merge(%{changed_files: []}, completed()))

      html = render_changed_files_task(task)

      refute html =~ "data-review-diff-panel"
    end

    test "file rows are targeted at this component, not the parent LiveView",
         %{column: column} do
      task = changed_files_task(column, completed())

      html = render_changed_files_task(task)

      assert html =~ "data-review-diff-panel-file-button"
      assert html =~ ~s(phx-click="select_changed_file")
      # Presence, not the value: render_component supplies a harness CID.
      assert html =~ "phx-target"
    end

    test "the panel inherits the theme-aware diff tokens from the task view root",
         %{column: column} do
      task = changed_files_task(column, completed())

      html = render_changed_files_task(task)

      # The dark-mode diff-line tokens are scoped to .stride-screen in app.css.
      assert html =~ ~s(class="stride-screen")
      refute html =~ "bg-gray-"
      refute html =~ "text-gray-"
      refute html =~ "bg-white"
    end

    test "selecting a file stores that file's whole changed_files entry",
         %{column: column} do
      task = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/foo.ex")

      assert %{"path" => "lib/foo.ex", "diff" => diff} = socket.assigns.selected_changed_file
      assert diff =~ "+new foo"
    end

    test "a path absent from the task's changed_files selects nothing and is not echoed",
         %{column: column} do
      task = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/ghost.ex")

      assert socket.assigns.selected_changed_file == nil
      refute inspect(socket.assigns) =~ "lib/ghost.ex"
    end

    test "clicking the already-selected file collapses it", %{column: column} do
      task = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/foo.ex")
      assert socket.assigns.selected_changed_file

      socket = select_file(socket, "lib/foo.ex")
      assert socket.assigns.selected_changed_file == nil
    end

    test "the selection is cleared when the component is updated for a different task",
         %{column: column} do
      task = changed_files_task(column, completed())
      other = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/foo.ex")
      assert socket.assigns.selected_changed_file

      {:ok, socket} =
        KanbanWeb.TaskLive.ViewComponent.update(
          %{id: "test-view", task_id: other.id, field_visibility: all_fields_visible()},
          socket
        )

      assert socket.assigns.selected_changed_file == nil
    end

    test "the selection survives a re-render of the SAME task with other assigns changed",
         %{column: column} do
      task = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/foo.ex")

      {:ok, socket} =
        KanbanWeb.TaskLive.ViewComponent.update(
          %{
            id: "test-view",
            task_id: task.id,
            can_modify: true,
            field_visibility: all_fields_visible()
          },
          socket
        )

      assert %{"path" => "lib/foo.ex"} = socket.assigns.selected_changed_file
    end

    test "a caller cannot seed the selection through the assigns map", %{column: column} do
      task = changed_files_task(column, completed())
      injected = %{"path" => "lib/injected.ex", "diff" => "+ never resolved"}

      # On first mount the caller's value is dropped outright.
      socket = build_view_socket(task.id, %{selected_changed_file: injected})
      assert socket.assigns.selected_changed_file == nil

      # And on a same-task re-render it cannot overwrite the component's own
      # selection either — handle_event/3 is the only way in.
      socket = select_file(socket, "lib/foo.ex")

      {:ok, socket} =
        KanbanWeb.TaskLive.ViewComponent.update(
          %{
            id: "test-view",
            task_id: task.id,
            field_visibility: all_fields_visible(),
            selected_changed_file: injected
          },
          socket
        )

      assert %{"path" => "lib/foo.ex"} = socket.assigns.selected_changed_file
      refute inspect(socket.assigns) =~ "lib/injected.ex"
    end

    test "an event with a missing or non-binary path leaves the selection untouched",
         %{column: column} do
      task = changed_files_task(column, completed())

      socket = task.id |> build_view_socket() |> select_file("lib/foo.ex")

      for params <- [%{}, %{"path" => nil}, %{"path" => 42}] do
        {:noreply, unchanged} =
          KanbanWeb.TaskLive.ViewComponent.handle_event(
            "select_changed_file",
            params,
            socket
          )

        assert %{"path" => "lib/foo.ex"} = unchanged.assigns.selected_changed_file
      end
    end
  end
end
