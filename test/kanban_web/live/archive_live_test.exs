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

    test "renders a month header above each group of rows",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Test Task"})
      {:ok, _} = Tasks.archive_task(task)

      {:ok, _index_live, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-month-header"
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

    test "filter_archive event narrows the visible rows to the selected reason",
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
      assert html =~ "Completed Work"
      assert html =~ "Cancelled Work"

      # Narrow to :cancelled — only that task should remain
      filtered =
        render_click(index_live, "filter_archive", %{"reason" => "cancelled"})

      refute filtered =~ "Completed Work"
      assert filtered =~ "Cancelled Work"
    end

    test "export_csv event flashes a 'coming soon' notice",
         %{conn: conn, board: board} do
      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      html = render_click(index_live, "export_csv", %{})
      assert html =~ "Export CSV — coming soon."
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

    for reason <- ["cancelled", "wontdo", "duplicate", "deferred"] do
      test "filter_archive narrows to :#{reason} reason",
           %{conn: conn, board: board, column: column} do
        own = task_fixture(column, %{title: "Keeper"})
        other = task_fixture(column, %{title: "Excluded"})

        own_reason = String.to_existing_atom(unquote(reason))

        own_attrs =
          if own_reason == :duplicate do
            canonical = task_fixture(column, %{title: "Canonical"})
            %{archive_reason: :duplicate, duplicate_of_id: canonical.id}
          else
            %{archive_reason: own_reason, archive_note: "necessary"}
          end

        {:ok, _} = Tasks.archive_task(own, own_attrs)
        {:ok, _} = Tasks.archive_task(other, %{archive_reason: :completed})

        {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

        html = render_click(index_live, "filter_archive", %{"reason" => unquote(reason)})

        assert html =~ "Keeper"
        refute html =~ "Excluded"
      end
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

    test "filter narrowed to zero rows shows the empty-state copy",
         %{conn: conn, board: board, column: column} do
      task = task_fixture(column, %{title: "Only completed"})
      {:ok, _} = Tasks.archive_task(task, %{archive_reason: :completed})

      {:ok, index_live, _html} = live(conn, ~p"/boards/#{board}/archive")

      # Narrow to :cancelled — no rows match
      html = render_click(index_live, "filter_archive", %{"reason" => "cancelled"})

      assert html =~ "data-archive-empty"
      assert html =~ "No archived tasks match this filter."
      refute html =~ "Only completed"
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

    test "renders the footer hint copy and Export CSV trigger",
         %{conn: conn, board: board, column: column} do
      task_fixture(column, %{title: "Test Task"}) |> Tasks.archive_task()

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      assert html =~ "data-archive-footer"
      assert html =~ "Archive is read-only after 180 days."
      assert html =~ "data-archive-export-csv"
      assert html =~ "Export CSV"
    end

    test "month grouping renders newest-month headers first",
         %{conn: conn, board: board, column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      sixty_days_ago = DateTime.add(now, -60 * 86_400, :second)

      this_month = task_fixture(column, %{title: "This month"})
      old = task_fixture(column, %{title: "Two months back"})

      {:ok, _} = Tasks.archive_task(this_month)

      {:ok, _} =
        Kanban.Tasks.update_task(old, %{archived_at: sixty_days_ago})

      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/archive")

      this_month_label =
        Date.utc_today() |> Calendar.strftime("%B %Y")

      old_month_label =
        sixty_days_ago
        |> DateTime.to_date()
        |> Calendar.strftime("%B %Y")

      # Both month headers render
      assert html =~ this_month_label
      assert html =~ old_month_label

      # Newest first — current-month header appears before the older one.
      assert :binary.match(html, this_month_label) <
               :binary.match(html, old_month_label)
    end
  end

  defp create_board_with_column(%{user: user}) do
    board = board_fixture(user)
    column = column_fixture(board, %{name: "Test Column"})
    %{board: board, column: column}
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
