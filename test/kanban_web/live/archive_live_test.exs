defmodule KanbanWeb.ArchiveLiveTest do
  use KanbanWeb.ConnCase

  import Ecto.Query, only: [where: 3]
  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "Archive Index" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "displays archive page with board name", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-screen"
      assert html =~ "Archive"
      assert html =~ board.name
    end

    test "displays back to board link", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Back to Board"
      assert html =~ ~p"/boards/#{board}"
    end

    test "displays the new stats strip and filter chips", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-stats-strip"
      assert html =~ "data-archive-filter-chips"
    end

    test "displays empty state when no archived tasks exist", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-empty"
      assert html =~ "No archived tasks match this filter."
    end

    test "displays archived tasks via the ArchiveRow component",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task", type: :work})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      refute html =~ "data-archive-empty"
      assert html =~ "data-archive-row"
      assert html =~ "Test Task"
      assert html =~ archived_task.identifier
    end

    test "renders the type icon for each archived task type",
         %{conn: conn, board: board, column: column} do
      work = task_fixture(column, %{title: "Work Task", type: :work})
      defect = task_fixture(column, %{title: "Defect Task", type: :defect})
      goal = task_fixture(column, %{title: "Goal Task", type: :goal})

      Tasks.archive_task(work)
      Tasks.archive_task(defect)
      Tasks.archive_task(goal)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "hero-document-text"
      assert html =~ "hero-bug-ant"
      assert html =~ "hero-flag"
    end

    test "does not render month section headers",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _} = Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      refute html =~ "data-archive-month-header"
    end

    test "renders the kebab action menu trigger when user can modify",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-row-kebab"
    end

    test "unarchive button restores task to board", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Test Task"

      # Click unarchive button
      index_live |> render_click("unarchive", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "Task unarchived successfully"

      # Verify task is no longer in archived list
      refute html =~ "Test Task"
    end

    test "unarchive event reloads archived tasks list", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      {:ok, archived_task1} = Tasks.archive_task(task1)
      {:ok, _archived_task2} = Tasks.archive_task(task2)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Task 1"
      assert html =~ "Task 2"

      # Unarchive task 1
      index_live |> render_click("unarchive", %{"id" => archived_task1.id})

      html = render(index_live)
      refute html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "delete button removes task permanently", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Test Task"

      # Click delete button
      index_live |> render_click("delete", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Test Task"

      # Verify task no longer exists in database
      assert_raise Ecto.NoResultsError, fn ->
        Tasks.get_task!(archived_task.id)
      end
    end

    test "displays multiple archived tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      task1 = task_fixture(column, %{title: "First Task"})
      task2 = task_fixture(column, %{title: "Second Task"})
      task3 = task_fixture(column, %{title: "Third Task"})

      Tasks.archive_task(task1)
      Tasks.archive_task(task2)
      Tasks.archive_task(task3)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      # All tasks should be displayed
      assert html =~ "First Task"
      assert html =~ "Second Task"
      assert html =~ "Third Task"
    end

    test "only displays archived tasks, not active tasks", %{
      conn: conn,
      board: board,
      column: column
    } do
      archived_task = task_fixture(column, %{title: "Archived Task"})
      _active_task = task_fixture(column, %{title: "Active Task"})

      Tasks.archive_task(archived_task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Archived Task"
      refute html =~ "Active Task"
    end

    test "cannot access archive page for other users' boards", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => _}}}} =
        live(conn, ~p"/boards/#{other_board}/archive")
    end

    test "handles task_updated PubSub event", %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Original Title"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Update the task
      {:ok, _updated_task} = Tasks.update_task(archived_task, %{title: "Updated Title"})

      html = render(index_live)
      assert html =~ "Updated Title"
    end

    test "handles task_deleted PubSub event", %{conn: conn, board: board, column: column} do
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      {:ok, archived_task1} = Tasks.archive_task(task1)
      {:ok, _archived_task2} = Tasks.archive_task(task2)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Task 1"
      assert html =~ "Task 2"

      # Delete task 1
      {:ok, _} = Tasks.delete_task(archived_task1)

      html = render(index_live)
      refute html =~ "Task 1"
      assert html =~ "Task 2"
    end

    test "user with read-only access sees archived tasks but no action buttons", %{
      conn: conn,
      user: user
    } do
      # Create a board owned by another user
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "Test Column"})

      # Grant read-only access to the current user
      Kanban.Boards.add_user_to_board(board, user, :read_only, owner)

      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Test Task"

      # Open the menu for this row — the buttons are gated by @can_modify
      # so a read-only viewer should see the "Read-only access" placeholder
      # instead.
      kebab_html =
        render_click(index_live, "open_archive_menu", %{"id" => task.id})

      assert kebab_html =~ "data-archive-menu-read-only"
      refute kebab_html =~ "data-archive-menu-restore"
      refute kebab_html =~ "data-archive-menu-delete"
    end

    test "shows error message when unarchive fails", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Try to unarchive with invalid ID
      index_live |> render_click("unarchive", %{"id" => 999_999})

      html = render(index_live)
      assert html =~ "Failed to unarchive task"
    end

    test "read-only user is rejected when pushing unarchive event", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "Test Column"})
      Kanban.Boards.add_user_to_board(board, user, :read_only, owner)

      task = task_fixture(column, %{title: "Read-only Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # A malicious client can push the event even though the UI button is hidden.
      index_live |> render_click("unarchive", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "You do not have permission to unarchive tasks on this board"

      # Task stayed archived.
      assert %{archived_at: archived_at} = Tasks.get_task!(archived_task.id)
      refute is_nil(archived_at)
    end

    test "cross-board task id is rejected when pushing unarchive event", %{
      conn: conn,
      board: own_board,
      user: user
    } do
      # Build a second board that the current user cannot modify, archive a task on it.
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board, %{name: "Other Column"})
      other_task = task_fixture(other_column, %{title: "Cross-Board Task"})
      {:ok, archived_other_task} = Tasks.archive_task(other_task)

      # Current user owns own_board and visits its archive page.
      {:ok, index_live, _html} = live(conn, ~p"/boards/#{own_board}/archive")

      # Push the cross-board archived task id through the unarchive event.
      index_live |> render_click("unarchive", %{"id" => archived_other_task.id})

      html = render(index_live)
      assert html =~ "Failed to unarchive task"

      # Cross-board task stayed archived.
      assert %{archived_at: archived_at} = Tasks.get_task!(archived_other_task.id)
      refute is_nil(archived_at)

      # Guard against unused variable warning.
      _ = user
    end

    test "shows error message when delete fails", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Try to delete with invalid ID
      index_live |> render_click("delete", %{"id" => 999_999})

      html = render(index_live)
      assert html =~ "Failed to delete task"
    end

    test "read-only user is rejected when pushing delete event", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "Test Column"})
      Kanban.Boards.add_user_to_board(board, user, :read_only, owner)

      task = task_fixture(column, %{title: "Read-only Delete Target"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      index_live |> render_click("delete", %{"id" => archived_task.id})

      html = render(index_live)
      assert html =~ "You do not have permission to delete tasks on this board"

      # Task still exists (not deleted).
      assert %{} = Tasks.get_task!(archived_task.id)
    end

    test "cross-board task id is rejected when pushing delete event", %{
      conn: conn,
      board: own_board,
      user: user
    } do
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      other_column = column_fixture(other_board, %{name: "Other Column"})
      other_task = task_fixture(other_column, %{title: "Cross-Board Delete"})
      {:ok, archived_other_task} = Tasks.archive_task(other_task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{own_board}/archive")

      index_live |> render_click("delete", %{"id" => archived_other_task.id})

      html = render(index_live)
      assert html =~ "Failed to delete task"

      # Cross-board task was not deleted.
      assert %{} = Tasks.get_task!(archived_other_task.id)

      _ = user
    end

    test "non-archived task id is rejected when pushing delete event", %{
      conn: conn,
      board: board,
      column: column
    } do
      # A task that is NOT archived must not be deletable via the archive page.
      task = task_fixture(column, %{title: "Active Task"})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      index_live |> render_click("delete", %{"id" => task.id})

      html = render(index_live)
      assert html =~ "Failed to delete task"

      # Active task was not deleted.
      assert %{} = Tasks.get_task!(task.id)
    end

    test "string-encoded id is accepted by unarchive happy path", %{
      conn: conn,
      board: board,
      column: column
    } do
      # Drag-and-drop and phx-value-id payloads arrive as strings; the parse_id
      # binary branch must accept fully-numeric strings.
      task = task_fixture(column, %{title: "String ID Task"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Push a string id (not the integer); render_click coerces to whatever we pass.
      index_live |> render_click("unarchive", %{"id" => to_string(archived_task.id)})

      html = render(index_live)
      assert html =~ "Task unarchived successfully"
    end

    test "non-numeric id is rejected by unarchive without raising", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Untouchable"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # A crafted payload with a non-numeric id must produce the standard error
      # flash, NOT crash the LiveView.
      index_live |> render_click("unarchive", %{"id" => "definitely-not-a-number"})

      html = render(index_live)
      assert html =~ "Failed to unarchive task"

      # Original archived task is untouched.
      assert %{archived_at: archived_at} = Tasks.get_task!(archived_task.id)
      refute is_nil(archived_at)
    end

    test "non-numeric id is rejected by delete without raising", %{
      conn: conn,
      board: board,
      column: column
    } do
      task = task_fixture(column, %{title: "Untouchable Delete"})
      {:ok, archived_task} = Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      index_live |> render_click("delete", %{"id" => "not-a-number"})

      html = render(index_live)
      assert html =~ "Failed to delete task"

      # Original archived task is untouched.
      assert %{} = Tasks.get_task!(archived_task.id)
    end

    test "handle_info ignores unknown messages without crashing", %{
      conn: conn,
      board: board
    } do
      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Send a message that doesn't match any specific handle_info clause.
      send(index_live.pid, {:something_unrelated, :payload})

      # Render must still succeed — the catch-all clause swallows the message.
      assert render(index_live) =~ "data-archive-screen"
    end

    test "filter_archive narrows to :completed; a removed-reason task still shows under :all",
         %{conn: conn, board: board, column: column} do
      completed = task_fixture(column, %{title: "Completed Work"})
      cancelled = task_fixture(column, %{title: "Cancelled Work"})

      {:ok, _} = Tasks.archive_task(completed, %{archive_reason: :completed})

      {:ok, _} =
        Tasks.archive_task(cancelled, %{
          archive_reason: :cancelled,
          archive_note: "Killed in flight"
        })

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      # The default :all view shows every archived row, including the task
      # carrying a removed reason (:cancelled) — no archived data is hidden.
      assert html =~ "Completed Work"
      assert html =~ "Cancelled Work"

      # Narrow to :completed — only the completed task remains; the
      # removed-reason task is filtered out of the Completed bucket.
      filtered =
        render_click(index_live, "filter_archive", %{"reason" => "completed"})

      assert filtered =~ "Completed Work"
      refute filtered =~ "Cancelled Work"
    end

    test "open_archive_menu reveals Restore + Delete buttons for an owner",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "open_archive_menu", %{"id" => task.id})

      assert html =~ "data-archive-row-menu"
      assert html =~ "data-archive-menu-restore"
      assert html =~ "data-archive-menu-delete"
      assert html =~ "Restore"
      assert html =~ "Delete forever"
    end

    test "close_archive_menu hides the menu",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      Tasks.archive_task(task)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      opened = render_click(index_live, "open_archive_menu", %{"id" => task.id})
      assert opened =~ "data-archive-row-menu"

      closed = render_click(index_live, "close_archive_menu", %{})
      refute closed =~ "data-archive-row-menu"
    end

    test "opening the menu for a second task closes the first menu",
         %{conn: conn, board: board, column: column} do
      a = task_fixture(column, %{title: "First"})
      b = task_fixture(column, %{title: "Second"})
      Tasks.archive_task(a)
      Tasks.archive_task(b)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      _ = render_click(index_live, "open_archive_menu", %{"id" => a.id})
      html = render_click(index_live, "open_archive_menu", %{"id" => b.id})

      # The :menu_open_for assign holds only one id at a time, so only one
      # menu overlay should be rendered after switching.
      menus = Regex.scan(~r/data-archive-row-menu/, html)
      assert length(menus) == 1
    end

    test "filter_archive correctly buckets :completed including legacy nil-reason rows",
         %{conn: conn, board: board, column: column} do
      legacy = task_fixture(column, %{title: "Legacy archived"})
      explicit = task_fixture(column, %{title: "Explicitly completed"})

      {:ok, _} = Tasks.archive_task(legacy, %{archive_reason: nil})
      {:ok, _} = Tasks.archive_task(explicit, %{archive_reason: :completed})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "filter_archive", %{"reason" => "completed"})

      assert html =~ "Legacy archived"
      assert html =~ "Explicitly completed"
    end

    @tag :capture_log
    test "filter_archive with an unknown reason falls back to :all and renders every row",
         %{conn: conn, board: board, column: column} do
      keeper = task_fixture(column, %{title: "Stays visible"})
      {:ok, _} = Tasks.archive_task(keeper, %{archive_reason: :completed})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "filter_archive", %{"reason" => "totally-bogus"})

      assert html =~ "Stays visible"
      # Logger.warning is fired on the server side; we don't assert log
      # contents here, but the absence of a crash + the keeper still
      # rendering proves the :all fallback path executes.
    end

    test "filter_archive with the \"all\" reason renders every archived row",
         %{conn: conn, board: board, column: column} do
      completed = task_fixture(column, %{title: "Completed one"})
      cancelled = task_fixture(column, %{title: "Cancelled one"})
      {:ok, _} = Tasks.archive_task(completed, %{archive_reason: :completed})

      {:ok, _} =
        Tasks.archive_task(cancelled, %{
          archive_reason: :cancelled,
          archive_note: "no longer needed"
        })

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Narrow first, then widen back to "all" to exercise parse_filter("all").
      render_click(index_live, "filter_archive", %{"reason" => "completed"})
      html = render_click(index_live, "filter_archive", %{"reason" => "all"})

      assert html =~ "Completed one"
      assert html =~ "Cancelled one"
    end

    test "filter narrowed to zero rows shows the empty-state copy",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Only cancelled"})

      {:ok, _} =
        Tasks.archive_task(task, %{archive_reason: :cancelled, archive_note: "nope"})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Narrow to :completed — the only archived task carries a removed reason,
      # so the Completed bucket is empty and the empty-state copy shows.
      html = render_click(index_live, "filter_archive", %{"reason" => "completed"})

      assert html =~ "data-archive-empty"
      assert html =~ "No archived tasks match this filter."
      refute html =~ "Only cancelled"
    end

    test "opening the assignee menu lists each archived assignee plus Unassigned and All assignees",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      grace = user_fixture(%{name: "Grace Hopper"})

      a1 = task_fixture(column, %{title: "Ada one", assigned_to_id: ada.id})
      a2 = task_fixture(column, %{title: "Ada two", assigned_to_id: ada.id})
      g1 = task_fixture(column, %{title: "Grace one", assigned_to_id: grace.id})
      none = task_fixture(column, %{title: "Nobody"})

      for t <- [a1, a2, g1, none], do: {:ok, _} = Tasks.archive_task(t)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "toggle_assignee_menu", %{})

      assert html =~ "data-archive-assignee-menu"
      assert html =~ "All assignees"
      assert html =~ "Ada Lovelace"
      assert html =~ "Grace Hopper"
      assert html =~ "Unassigned"
      # Each distinct assignee appears once as an option.
      assert html =~ ~s(data-archive-assignee-option="#{ada.id}")
      assert html =~ ~s(data-archive-assignee-option="#{grace.id}")
      assert length(Regex.scan(~r/data-archive-assignee-option="#{ada.id}"/, html)) == 1
    end

    test "selecting an assignee filters to that user's rows and closes the menu",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      grace = user_fixture(%{name: "Grace Hopper"})

      ada_task = task_fixture(column, %{title: "Ada task", assigned_to_id: ada.id})
      grace_task = task_fixture(column, %{title: "Grace task", assigned_to_id: grace.id})
      none = task_fixture(column, %{title: "Unassigned task"})

      for t <- [ada_task, grace_task, none], do: {:ok, _} = Tasks.archive_task(t)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html =
        render_click(index_live, "filter_assignee", %{"assignee" => to_string(ada.id)})

      assert html =~ "Ada task"
      refute html =~ "Grace task"
      refute html =~ "Unassigned task"
      # The dropdown closes after a selection.
      refute html =~ "data-archive-assignee-menu"
    end

    test "selecting Unassigned narrows to nil-assignee rows",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})

      ada_task = task_fixture(column, %{title: "Ada task", assigned_to_id: ada.id})
      none = task_fixture(column, %{title: "Unassigned task"})

      for t <- [ada_task, none], do: {:ok, _} = Tasks.archive_task(t)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "filter_assignee", %{"assignee" => "unassigned"})

      assert html =~ "Unassigned task"
      refute html =~ "Ada task"
    end

    test "selecting All assignees clears the assignee filter",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})

      ada_task = task_fixture(column, %{title: "Ada task", assigned_to_id: ada.id})
      none = task_fixture(column, %{title: "Unassigned task"})

      for t <- [ada_task, none], do: {:ok, _} = Tasks.archive_task(t)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(index_live, "filter_assignee", %{"assignee" => to_string(ada.id)})
      html = render_click(index_live, "filter_assignee", %{"assignee" => "all"})

      assert html =~ "Ada task"
      assert html =~ "Unassigned task"
    end

    test "the assignee filter composes with the reason filter and survives a PubSub reload",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      grace = user_fixture(%{name: "Grace Hopper"})

      ada_completed =
        task_fixture(column, %{title: "Ada completed", assigned_to_id: ada.id})

      ada_cancelled =
        task_fixture(column, %{title: "Ada cancelled", assigned_to_id: ada.id})

      grace_completed =
        task_fixture(column, %{title: "Grace completed", assigned_to_id: grace.id})

      {:ok, _} = Tasks.archive_task(ada_completed, %{archive_reason: :completed})

      {:ok, _} =
        Tasks.archive_task(ada_cancelled, %{
          archive_reason: :cancelled,
          archive_note: "stop"
        })

      {:ok, _} = Tasks.archive_task(grace_completed, %{archive_reason: :completed})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Compose Completed reason AND Ada assignee.
      render_click(index_live, "filter_archive", %{"reason" => "completed"})
      html = render_click(index_live, "filter_assignee", %{"assignee" => to_string(ada.id)})

      assert html =~ "Ada completed"
      # Reason filter excludes Ada's cancelled task; assignee filter excludes Grace.
      refute html =~ "Ada cancelled"
      refute html =~ "Grace completed"

      # A PubSub reload must preserve BOTH dimensions.
      send(index_live.pid, {Kanban.Tasks, :task_updated, ada_completed})
      reloaded = render(index_live)

      assert reloaded =~ "Ada completed"
      refute reloaded =~ "Ada cancelled"
      refute reloaded =~ "Grace completed"
    end

    test "the Unassigned option is absent when every archived task has an assignee",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      a1 = task_fixture(column, %{title: "Ada one", assigned_to_id: ada.id})
      {:ok, _} = Tasks.archive_task(a1)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "toggle_assignee_menu", %{})

      assert html =~ "Ada Lovelace"
      refute html =~ ~s(data-archive-assignee-option="unassigned")
    end

    test "close_assignee_menu closes the dropdown",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      a1 = task_fixture(column, %{title: "Ada one", assigned_to_id: ada.id})
      {:ok, _} = Tasks.archive_task(a1)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      opened = render_click(index_live, "toggle_assignee_menu", %{})
      assert opened =~ "data-archive-assignee-menu"

      closed = render_click(index_live, "close_assignee_menu", %{})
      refute closed =~ "data-archive-assignee-menu"
    end

    test "filter_assignee with an unparseable value falls back to :all without crashing",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      ada_task = task_fixture(column, %{title: "Ada task", assigned_to_id: ada.id})
      none = task_fixture(column, %{title: "Unassigned task"})

      for t <- [ada_task, none], do: {:ok, _} = Tasks.archive_task(t)

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "filter_assignee", %{"assignee" => "not-a-number"})

      # Degrades to :all — both rows remain visible, no crash.
      assert html =~ "Ada task"
      assert html =~ "Unassigned task"
    end

    test "filter_date_range narrows rows to those archived within the inclusive range",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "Early Jan", ~U[2026-01-10 12:00:00Z])
      archive_on(column, "Mid Jan", ~U[2026-01-15 12:00:00Z])
      archive_on(column, "Late Jan", ~U[2026-01-20 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      html =
        render_click(view, "filter_date_range", %{"from" => "2026-01-12", "to" => "2026-01-18"})

      assert html =~ "Mid Jan"
      refute html =~ "Early Jan"
      refute html =~ "Late Jan"
    end

    test "filter_date_range includes rows archived on the from/to boundary dates",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "On From", ~U[2026-01-10 23:59:59Z])
      archive_on(column, "On To", ~U[2026-01-20 00:00:01Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      html =
        render_click(view, "filter_date_range", %{"from" => "2026-01-10", "to" => "2026-01-20"})

      assert html =~ "On From"
      assert html =~ "On To"
    end

    test "filter_date_range supports open-ended ranges (only from, or only to)",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "Early", ~U[2026-01-10 12:00:00Z])
      archive_on(column, "Late", ~U[2026-01-20 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      only_from = render_click(view, "filter_date_range", %{"from" => "2026-01-15", "to" => ""})
      assert only_from =~ "Late"
      refute only_from =~ "Early"

      only_to = render_click(view, "filter_date_range", %{"from" => "", "to" => "2026-01-15"})
      assert only_to =~ "Early"
      refute only_to =~ "Late"
    end

    test "clear_date_range restores the rows matching the other filters",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "Early", ~U[2026-01-10 12:00:00Z])
      archive_on(column, "Late", ~U[2026-01-20 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(view, "filter_date_range", %{"from" => "2026-01-18", "to" => ""})
      cleared = render_click(view, "clear_date_range", %{})

      assert cleared =~ "Early"
      assert cleared =~ "Late"
    end

    test "the date filter composes with the reason filter",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "Completed in range", ~U[2026-01-15 12:00:00Z], %{
        archive_reason: :completed
      })

      archive_on(column, "Cancelled in range", ~U[2026-01-15 12:00:00Z], %{
        archive_reason: :cancelled,
        archive_note: "stop"
      })

      archive_on(column, "Completed out of range", ~U[2026-02-15 12:00:00Z], %{
        archive_reason: :completed
      })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(view, "filter_archive", %{"reason" => "completed"})

      html =
        render_click(view, "filter_date_range", %{"from" => "2026-01-01", "to" => "2026-01-31"})

      assert html =~ "Completed in range"
      # Excluded by the reason filter.
      refute html =~ "Cancelled in range"
      # Excluded by the date filter.
      refute html =~ "Completed out of range"
    end

    test "filter_date_range with an invalid date string degrades to an open bound without crashing",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "Early", ~U[2026-01-10 12:00:00Z])
      archive_on(column, "Late", ~U[2026-01-20 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      # "from" is garbage -> nil (open lower bound); "to" still caps at the 15th.
      html =
        render_click(view, "filter_date_range", %{"from" => "not-a-date", "to" => "2026-01-15"})

      assert html =~ "Early"
      refute html =~ "Late"
    end

    test "search_archive narrows rows to titles matching the query (case-insensitive)",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()
      task_fixture(column, %{title: "Write docs"}) |> Tasks.archive_task()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Lowercase query matches the mixed-case title by substring.
      html = render_hook(view, "search_archive", %{"query" => "deploy"})
      assert html =~ "Deploy pipeline"
      refute html =~ "Write docs"
    end

    test "an empty/whitespace search query restores all rows",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()
      task_fixture(column, %{title: "Write docs"}) |> Tasks.archive_task()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_hook(view, "search_archive", %{"query" => "deploy"})
      restored = render_hook(view, "search_archive", %{"query" => "   "})

      assert restored =~ "Deploy pipeline"
      assert restored =~ "Write docs"
    end

    test "a search query matching no titles yields an empty result without crashing",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_hook(view, "search_archive", %{"query" => "nonexistent"})
      refute html =~ "Deploy pipeline"
      assert html =~ "No archived tasks match this filter."
    end

    test "search composes with the reason filter",
         %{conn: conn, board: board, column: column} do
      completed = task_fixture(column, %{title: "Deploy completed"})
      cancelled = task_fixture(column, %{title: "Deploy cancelled"})
      {:ok, _} = Tasks.archive_task(completed, %{archive_reason: :completed})

      {:ok, _} =
        Tasks.archive_task(cancelled, %{archive_reason: :cancelled, archive_note: "stop"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(view, "filter_archive", %{"reason" => "completed"})
      html = render_hook(view, "search_archive", %{"query" => "deploy"})

      assert html =~ "Deploy completed"
      # Excluded by the reason filter even though the title matches the search.
      refute html =~ "Deploy cancelled"
    end

    test "search composes with the assignee filter",
         %{conn: conn, board: board, column: column} do
      ada = user_fixture(%{name: "Ada Lovelace"})
      ada_task = task_fixture(column, %{title: "Deploy by Ada", assigned_to_id: ada.id})
      other_task = task_fixture(column, %{title: "Deploy by nobody"})
      {:ok, _} = Tasks.archive_task(ada_task)
      {:ok, _} = Tasks.archive_task(other_task)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(view, "filter_assignee", %{"assignee" => to_string(ada.id)})
      html = render_hook(view, "search_archive", %{"query" => "deploy"})

      assert html =~ "Deploy by Ada"
      # Excluded by the assignee filter even though the title matches the search.
      refute html =~ "Deploy by nobody"
    end

    test "renders the archive search input with no clear control when empty",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-search"
      # The clear (x) affordance is hidden while the query is empty.
      refute html =~ "data-archive-search-clear"
    end

    test "typing in the search input narrows the rendered rows and reveals the clear control",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()
      task_fixture(column, %{title: "Write docs"}) |> Tasks.archive_task()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      html =
        view
        |> element("form[phx-change='search_archive']")
        |> render_change(%{"query" => "deploy"})

      assert html =~ "Deploy pipeline"
      refute html =~ "Write docs"
      assert html =~ "data-archive-search-clear"
    end

    test "the search clear control resets the search and restores rows",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Deploy pipeline"}) |> Tasks.archive_task()
      task_fixture(column, %{title: "Write docs"}) |> Tasks.archive_task()

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      view
      |> element("form[phx-change='search_archive']")
      |> render_change(%{"query" => "deploy"})

      cleared = view |> element("[data-archive-search-clear]") |> render_click()

      assert cleared =~ "Deploy pipeline"
      assert cleared =~ "Write docs"
      refute cleared =~ "data-archive-search-clear"
    end

    test "clicking the Date range chip opens the date popover",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "A Task", ~U[2026-01-15 12:00:00Z])

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      refute html =~ "data-archive-date-menu"

      opened = render_click(view, "toggle_date_menu", %{})
      assert opened =~ "data-archive-date-menu"
      assert opened =~ "data-archive-date-from"
      assert opened =~ "data-archive-date-to"
    end

    test "submitting the From/To popover form narrows the rows and closes the popover",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "In Range", ~U[2026-01-15 12:00:00Z])
      archive_on(column, "Out Of Range", ~U[2026-02-15 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")
      render_click(view, "toggle_date_menu", %{})

      html =
        view
        |> element("[data-archive-date-menu] form")
        |> render_submit(%{"from" => "2026-01-01", "to" => "2026-01-31"})

      assert html =~ "In Range"
      refute html =~ "Out Of Range"
      # The popover closes after Apply, and the chip reflects the active range.
      refute html =~ "data-archive-date-menu"
      assert html =~ "2026-01-01"
      assert html =~ "2026-01-31"
    end

    test "the Date range chip Clear button resets the range and restores rows",
         %{conn: conn, board: board, column: column} do
      archive_on(column, "In Range", ~U[2026-01-15 12:00:00Z])
      archive_on(column, "Out Of Range", ~U[2026-02-15 12:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      render_click(view, "filter_date_range", %{"from" => "2026-01-01", "to" => "2026-01-31"})
      refute render(view) =~ "Out Of Range"

      # Re-open the popover and click Clear.
      render_click(view, "toggle_date_menu", %{})
      cleared = view |> element("[data-archive-date-clear]") |> render_click()

      assert cleared =~ "In Range"
      assert cleared =~ "Out Of Range"
      refute cleared =~ "data-archive-date-menu"
    end

    test "handle_info :task_deleted PubSub event triggers a reload",
         %{conn: conn, board: board, column: column} do
      keeper = task_fixture(column, %{title: "Sticks around"})
      gone = task_fixture(column, %{title: "Will disappear"})
      Tasks.archive_task(keeper)
      Tasks.archive_task(gone)

      {:ok, index_live, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Sticks around"
      assert html =~ "Will disappear"

      {:ok, _} = Tasks.delete_task(gone)

      html = render(index_live)
      assert html =~ "Sticks around"
      refute html =~ "Will disappear"
    end

    test "renders the footer hint copy and an Export CSV download link",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Test Task"}) |> Tasks.archive_task()

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-footer"
      # The misleading 180-day read-only claim is gone (no such rule exists).
      refute html =~ "Archive is read-only after 180 days."
      assert html =~ "searchable and in the audit log"
      assert html =~ "data-archive-export-csv"
      assert html =~ "Export CSV"
      # The Export CSV control is now a real download link to the controller.
      assert html =~ ~p"/boards/#{board}/archive/export"
    end

    test "archived rows spanning multiple months render in one flat goal-grouped list",
         %{conn: conn, board: board, column: column} do
      sixty_days_ago =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60 * 86_400, :second)

      this_month = task_fixture(column, %{title: "This month"})
      old = task_fixture(column, %{title: "Two months back"})

      {:ok, _} = Tasks.archive_task(this_month)
      {:ok, _} = Kanban.Tasks.update_task(old, %{archived_at: sixty_days_ago})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      # No month sections — both rows appear in the single flat list.
      refute html =~ "data-archive-month-header"
      assert html =~ this_month.identifier
      assert html =~ old.identifier
    end

    test "a present goal carries the chevron on its own row with no duplicate header line",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch flow", type: :goal})
      child = task_fixture(column, %{title: "Child of goal", type: :work, parent_id: goal.id})
      standalone = task_fixture(column, %{title: "Lonely task", type: :work})

      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)
      {:ok, _} = Tasks.archive_task(standalone)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")
      goal_key = goal_group_key(goal)

      # The goal's own row carries the chevron toggle (keys are month-qualified,
      # e.g. "2026-6:goal:5")...
      assert html =~ ~s(phx-value-group_key="#{goal_key}")
      assert html =~ goal.identifier

      # ...and there is NO separate goal-group header line for it (the duplicate
      # that this defect removes — headers carry data-archive-goal-group-key).
      refute html =~ ~s(data-archive-goal-group-key="#{goal_key}")

      # Standalone tasks still get a synthetic Tasks Without Goals header.
      assert html =~ ~s(data-archive-goal-group-key="#{no_goal_group_key()}")
      assert html =~ "Tasks Without Goals"

      # The Tasks Without Goals group renders at the top, above the goal groups.
      assert :binary.match(html, "no_goal") < :binary.match(html, goal_key)

      # Every archived row still renders.
      assert html =~ child.identifier
      assert html =~ standalone.identifier
    end

    test "toggling a present goal hides its children but keeps the goal row visible",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch flow", type: :goal})
      child = task_fixture(column, %{title: "Child of goal", type: :work, parent_id: goal.id})

      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ goal.identifier
      assert html =~ child.identifier

      html = toggle_goal_group(view, goal_group_key(goal))

      # The child row hides, but the goal's own row stays visible.
      refute html =~ child.identifier
      assert html =~ goal.identifier
      assert html =~ "hero-chevron-right"
    end

    test "a goal with no archived children renders no chevron",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Childless goal", type: :goal})
      {:ok, _} = Tasks.archive_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ goal.identifier
      refute html =~ "data-archive-goal-group-toggle"
    end

    test "the expand/collapse-all control collapses then expands every goal group",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      child = task_fixture(column, %{title: "Child Task", type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      # Expanded by default — the control offers "Collapse all".
      assert html =~ "data-archive-toggle-all-goals"
      assert html =~ "Collapse all"
      assert html =~ "Child Task"

      collapsed = render_click(view, "toggle_all_goal_groups", %{})
      # The child row hides; the goal's own row stays; the control flips.
      refute collapsed =~ "Child Task"
      assert collapsed =~ "Launch Goal"
      assert collapsed =~ "Expand all"

      expanded = render_click(view, "toggle_all_goal_groups", %{})
      assert expanded =~ "Child Task"
      assert expanded =~ "Collapse all"
    end

    test "the all-toggle composes with the per-group toggle_goal_group",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      child = task_fixture(column, %{title: "Child Task", type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Collapse everything, then expand just this one group via its chevron.
      render_click(view, "toggle_all_goal_groups", %{})
      refute render(view) =~ "Child Task"

      html = toggle_goal_group(view, goal_group_key(goal))
      assert html =~ "Child Task"
    end

    test "the expand/collapse-all control is hidden when there are no collapsible groups",
         %{conn: conn, board: board, column: column} do
      # A childless archived goal renders no chevron and forms no collapsible
      # group, so the control is hidden.
      goal = task_fixture(column, %{title: "Childless goal", type: :goal})
      {:ok, _} = Tasks.archive_task(goal)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      refute html =~ "data-archive-toggle-all-goals"
    end

    test "the expand/collapse-all control includes the Tasks Without Goals group",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      child = task_fixture(column, %{title: "Child Task", type: :work, parent_id: goal.id})
      standalone = task_fixture(column, %{title: "Standalone Task"})
      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)
      {:ok, _} = Tasks.archive_task(standalone)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      assert html =~ "Child Task"
      assert html =~ "Standalone Task"

      # Collapse-all hides BOTH the goal-group child and the no-goal standalone.
      collapsed = render_click(view, "toggle_all_goal_groups", %{})
      refute collapsed =~ "Child Task"
      refute collapsed =~ "Standalone Task"

      # Expand-all brings both back.
      expanded = render_click(view, "toggle_all_goal_groups", %{})
      assert expanded =~ "Child Task"
      assert expanded =~ "Standalone Task"
    end

    test "the control is shown and collapses a board with only ungrouped tasks",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Standalone Task"}) |> Tasks.archive_task()

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      # The no_goal group is collapsible, so the control is shown.
      assert html =~ "data-archive-toggle-all-goals"

      collapsed = render_click(view, "toggle_all_goal_groups", %{})
      refute collapsed =~ "Standalone Task"
    end

    test "a goal whose own row is not archived renders a synthetic header with the violet background",
         %{conn: conn, board: board, column: column} do
      # The goal stays active on the board; only its child is archived. The goal
      # appears in the archive solely as a synthetic header (no archived goal row).
      goal = task_fixture(column, %{title: "Active goal", type: :goal})
      child = task_fixture(column, %{title: "Archived child", type: :work, parent_id: goal.id})
      {:ok, _} = Tasks.archive_task(child)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      # Synthetic header for the goal, carrying the soft-violet goal background.
      assert html =~ ~s(data-archive-goal-group-key="#{goal_group_key(goal)}")
      assert html =~ "background: var(--stride-violet-soft)"
      assert html =~ child.identifier
    end

    test "the Tasks Without Goals header uses the goal violet background for consistency",
         %{conn: conn, board: board, column: column} do
      standalone = task_fixture(column, %{title: "Lonely task", type: :work})
      {:ok, _} = Tasks.archive_task(standalone)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "Tasks Without Goals"
      assert html =~ "background: var(--stride-violet-soft)"
    end

    test "collapses and expands a goal group when its chevron is toggled",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Launch flow", type: :goal})
      child = task_fixture(column, %{title: "Child of goal", type: :work, parent_id: goal.id})

      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(child)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      key = goal_group_key(goal)

      # Expanded by default: the child row is visible and the chevron points down.
      assert html =~ child.identifier
      assert html =~ "hero-chevron-down"

      # Collapsing hides the child row and flips the chevron to point right.
      html = toggle_goal_group(view, key)
      refute html =~ child.identifier
      assert html =~ "hero-chevron-right"

      # Expanding again brings the child row back.
      html = toggle_goal_group(view, key)
      assert html =~ child.identifier
    end

    test "the Tasks Without Goals group toggles like a goal group",
         %{conn: conn, board: board, column: column} do
      standalone = task_fixture(column, %{title: "Lonely task", type: :work})
      {:ok, _} = Tasks.archive_task(standalone)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/archive")
      key = no_goal_group_key()

      assert html =~ standalone.identifier

      html = toggle_goal_group(view, key)
      # The standalone row hides but the group header still renders.
      refute html =~ standalone.identifier
      assert html =~ "Tasks Without Goals"
    end

    test "renders goal rows with the violet background and non-goal rows on surface",
         %{conn: conn, board: board, column: column} do
      goal = task_fixture(column, %{title: "Violet goal", type: :goal})
      work = task_fixture(column, %{title: "Plain work", type: :work})
      defect = task_fixture(column, %{title: "A defect", type: :defect})

      {:ok, _} = Tasks.archive_task(goal)
      {:ok, _} = Tasks.archive_task(work)
      {:ok, _} = Tasks.archive_task(defect)

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      # The goal row carries the board goal-card violet; non-goal rows keep surface.
      assert html =~ "background: var(--stride-violet-soft)"
      assert html =~ "background: var(--surface)"

      # All three archived rows render.
      assert html =~ goal.identifier
      assert html =~ work.identifier
      assert html =~ defect.identifier
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Test Column"})
    %{board: board, column: column}
  end

  defp goal_group_key(goal), do: "goal:#{goal.id}"

  defp no_goal_group_key, do: "no_goal"

  defp toggle_goal_group(view, key) do
    view
    |> element(~s([data-archive-goal-group-toggle][phx-value-group_key="#{key}"]))
    |> render_click()
  end

  defp complete_task!(task, completed_at) do
    Kanban.Tasks.Task
    |> where([t], t.id == ^task.id)
    |> Kanban.Repo.update_all(set: [status: :completed, completed_at: completed_at])

    Kanban.Tasks.get_task!(task.id)
  end

  defp days_ago(days) do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.add(-days * 86_400, :second)
  end

  # Creates an archived task with a specific archived_at timestamp (and any
  # extra archive attrs), used by the date-range filter tests.
  defp archive_on(column, title, %DateTime{} = archived_at, extra \\ %{}) do
    {:ok, task} =
      column
      |> task_fixture(%{title: title})
      |> Tasks.update_task(Map.merge(%{archived_at: archived_at}, extra))

    task
  end

  describe "bulk archive button" do
    setup [:register_and_log_in_user, :create_board_with_column]

    test "renders the bulk archive button for owners", %{conn: conn, board: board} do
      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-bulk-old"
      assert html =~ "Archive old"
      assert html =~ "Archive all completed tasks older than 30 days?"
    end

    test "does not render the bulk archive button for read-only users", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      _column = column_fixture(board, %{name: "Test Column"})
      Kanban.Boards.add_user_to_board(board, user, :read_only, owner)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      refute html =~ "data-archive-bulk-old"
    end

    test "bulk_archive_old archives matching tasks and refreshes the list",
         %{conn: conn, board: board, column: column} do
      old_task =
        column
        |> task_fixture(%{title: "Old Done Task"})
        |> complete_task!(days_ago(45))

      recent_task =
        column
        |> task_fixture(%{title: "Recent Done Task"})
        |> complete_task!(days_ago(5))

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "bulk_archive_old")

      assert html =~ "Archived 1 completed task older than 30 days."
      assert html =~ "Old Done Task"

      assert Kanban.Tasks.get_task!(old_task.id).archived_at != nil
      assert Kanban.Tasks.get_task!(recent_task.id).archived_at == nil
    end

    test "bulk_archive_old flashes the pluralized count when several tasks match",
         %{conn: conn, board: board, column: column} do
      column
      |> task_fixture(%{title: "Old Done One"})
      |> complete_task!(days_ago(45))

      column
      |> task_fixture(%{title: "Old Done Two"})
      |> complete_task!(days_ago(50))

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "bulk_archive_old")

      assert html =~ "Archived 2 completed tasks older than 30 days."
    end

    test "bulk_archive_old flashes the zero-count message when no tasks match",
         %{conn: conn, board: board, column: column} do
      _recent =
        column
        |> task_fixture(%{title: "Recent Done Task"})
        |> complete_task!(days_ago(5))

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "bulk_archive_old")

      assert html =~ "No completed tasks older than 30 days were found."
    end

    test "read-only user pushing bulk_archive_old gets a permission error", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board, %{name: "Test Column"})
      Kanban.Boards.add_user_to_board(board, user, :read_only, owner)

      old_task =
        column
        |> task_fixture(%{title: "Old Done Task"})
        |> complete_task!(days_ago(45))

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "bulk_archive_old")

      assert html =~ "You do not have permission to archive tasks on this board"
      assert Kanban.Tasks.get_task!(old_task.id).archived_at == nil
    end
  end
end
