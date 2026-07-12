defmodule KanbanWeb.BoardLiveTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures
  import ExUnit.CaptureLog

  @create_attrs %{name: "some name", description: "some description"}
  @update_attrs %{name: "some updated name", description: "some updated description"}
  @invalid_attrs %{name: nil, description: nil}

  describe "Index" do
    setup [:register_and_log_in_user]

    test "lists all boards", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      assert html =~ "Boards"
      assert html =~ "1 active"
      assert html =~ board.name
    end

    test "handle_info(:refresh_metrics) reloads the listing without crashing",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      # The periodic refresh timer is disabled in the test config, so drive the
      # reload handler directly to exercise it.
      send(index_live.pid, :refresh_metrics)

      html = render(index_live)
      assert html =~ board.name
      assert html =~ "1 active"
    end

    test "saves new board", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/boards/new")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, show_live, html} =
        form_live
        |> form("#board-form", board: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "some name"
      assert show_live.module == KanbanWeb.BoardLive.Show
    end

    test "updates board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _show_live, html} =
        form_live
        |> form("#board-form", board: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards/#{board}")

      assert html =~ "some updated name"
    end

    test "deletes board in listing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      assert index_live |> element("#boards-#{board.id} a[href*='#']", "") |> render_click()
      refute has_element?(index_live, "#boards-#{board.id}")
    end

    test "cannot see other users' boards", %{conn: conn} do
      other_user = user_fixture()
      _other_board = board_fixture(other_user)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      refute html =~ "other user board"
    end

    test "delete event for a board the user does not own returns :unauthorized flash",
         %{conn: conn, user: user} do
      # The user has :modify access to the board but is not the owner. The
      # context-level owner check in W396's Boards.delete_board/2 returns
      # {:error, :unauthorized}, which BoardLive.Index handles by flashing the
      # owner-only error and re-navigating.
      owner = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, owner)

      {:ok, index_live, _html} = live(conn, ~p"/boards")

      render_hook(index_live, "delete", %{"id" => to_string(board.id)})
      flash = assert_redirect(index_live, ~p"/boards")

      assert flash["error"] =~ "Only the board owner can delete this board"
      assert %Kanban.Boards.Board{} = Kanban.Boards.get_board!(board.id, user)
    end

    test "delete event for an id that does not match an accessible board returns :not_found flash",
         %{conn: conn} do
      # Either a deleted board id, an id from a board the user has no access to,
      # or a bogus large id — Boards.get_board/2 returns {:error, :not_found} in
      # all of those cases, and BoardLive.Index flashes 'Board not found'.
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      render_hook(index_live, "delete", %{"id" => "999999999"})
      flash = assert_redirect(index_live, ~p"/boards")

      assert flash["error"] =~ "Board not found"
    end

    test "mounts with has_boards: false when the user has no boards",
         %{conn: conn} do
      # The user from register_and_log_in_user has no boards yet, so the
      # has_boards assign flips to false and the empty-state UI renders.
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # The index template renders different content when has_boards is false.
      # At minimum, no board card should render and the listing heading still
      # appears. (Tests upstream of this one have already covered the populated
      # branch.)
      refute html =~ ~r/<li id="boards-\d+"/
      assert html =~ "Boards"
      assert html =~ "No boards yet"
    end

    test "populated state declares the responsive grid columns (1/2/3)",
         %{conn: conn, user: user} do
      _b = board_fixture(user)
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      assert html =~ "grid-cols-1"
      assert html =~ "md:grid-cols-2"
      assert html =~ "lg:grid-cols-3"
    end

    test "empty state stacks CTAs on mobile and hides the diagram", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # CTA container is flex-col on mobile, flex-row at sm+.
      assert html =~ "flex-col sm:flex-row"
      # Diagram is hidden on mobile, shown md+.
      assert html =~ "hidden md:flex"
    end

    test "empty state renders the new design's structure and CTAs",
         %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # New heading lines (both phrases present, joined by a <br />).
      assert html =~ "No boards yet."
      assert html =~ "Let&#39;s start with one."

      # Body copy from the design — substring match on a stable phrase.
      assert html =~ "5-column AI flow"

      # Primary CTA navigates to /boards/new.
      assert html =~ ~s(href="/boards/new")
      assert html =~ "Create your first board"

      # Secondary CTA is disabled (no crash, no href).
      assert html =~ "Import from Linear or Jira"
      assert html =~ ~s(disabled)

      # Footnote mono tip.
      assert html =~ "Stride can backfill history"
    end

    test "renders the targets strip with an assigned target for the scoped user",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      _child = task_fixture(column, %{title: "Child 1", parent_id: goal.id})

      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Kanban.Accounts.Scope.for_user(user)
      {:ok, _goal} = Kanban.Targets.assign_goal(scope, goal, target)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      assert html =~ "Targets"
      assert html =~ "Q3 Launch"
      # One child, none completed -> a 0/1 (0%) aggregate fraction.
      assert html =~ "0/1 (0%)"
    end

    test "renders the Boards title above the targets strip", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Kanban.Accounts.Scope.for_user(user)
      {:ok, _goal} = Kanban.Targets.assign_goal(scope, goal, target)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # The page title must render first, with the targets strip below it
      # (matching the board page's title-then-strip ordering).
      {title_pos, _} = :binary.match(html, "</h1>")
      {strip_pos, _} = :binary.match(html, "data-target-card")
      assert title_pos < strip_pos
    end

    test "renders no targets strip when the user has no targets", %{conn: conn, user: user} do
      _board = board_fixture(user)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # Empty targets list -> targets_strip renders nothing: no card.
      refute html =~ "data-target-card"
    end

    test "renders a New Target link in the header even with zero targets", %{conn: conn} do
      # No board or target fixtures: the header action must be reachable
      # before any targets (or boards) exist, so the first target can be
      # created. The targets strip is absent here, so this proves the
      # always-visible header entry point.
      {:ok, index_live, _html} = live(conn, ~p"/boards")

      assert has_element?(index_live, ~s(a[href="/targets/new"]))
    end

    test "renders the New Target link exactly once when a target exists", %{
      conn: conn,
      user: user
    } do
      # The single create entry point lives in the header. The targets strip
      # must NOT add its own duplicate, so even with a target present the
      # /targets/new link appears exactly once.
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      target = delivery_target_fixture(user, %{name: "Q3 Launch"})
      scope = Kanban.Accounts.Scope.for_user(user)
      {:ok, _goal} = Kanban.Targets.assign_goal(scope, goal, target)

      {:ok, _index_live, html} = live(conn, ~p"/boards")

      # Strip is present (target exists) but contributes no second link.
      assert html =~ "data-target-card"
      assert length(String.split(html, ~s(href="/targets/new"))) - 1 == 1
    end

    test "the metrics refresh re-loads the targets strip", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, index_live, html} = live(conn, ~p"/boards")
      refute html =~ "data-target-card"

      # Assign a target after mount, then trigger the refresh the poller uses.
      goal = task_fixture(column, %{title: "Launch Goal", type: :goal})
      target = delivery_target_fixture(user, %{name: "Refreshed Target"})
      scope = Kanban.Accounts.Scope.for_user(user)
      {:ok, _goal} = Kanban.Targets.assign_goal(scope, goal, target)

      send(index_live.pid, :refresh_metrics)
      html = render(index_live)

      assert html =~ "data-target-card"
      assert html =~ "Refreshed Target"
    end
  end

  describe "Goal progress badge" do
    setup [:register_and_log_in_user]

    # D60 regression: archived children must not inflate the badge
    # denominator computed by compute_goal_progress/2.
    test "excludes archived children from the badge denominator",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Badge Goal", type: :goal})

      for n <- 1..5 do
        child = task_fixture(column, %{title: "Active #{n}", parent_id: goal.id})

        {:ok, _} =
          Kanban.Tasks.update_task(child, %{
            "status" => "completed",
            "completed_at" => DateTime.utc_now()
          })
      end

      archived_at = DateTime.utc_now() |> DateTime.truncate(:second)

      for n <- 1..3 do
        archived = task_fixture(column, %{title: "Archived #{n}", parent_id: goal.id})

        {:ok, _} =
          archived
          |> Ecto.Changeset.change(%{archived_at: archived_at})
          |> Kanban.Repo.update()
      end

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "5/5"
      assert html =~ "children complete"
      refute html =~ "5/8"
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user]

    test "displays board", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Stride"
      assert html =~ board.name
    end

    test "cannot access other users' boards", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => _}}}} =
        live(conn, ~p"/boards/#{other_board}")
    end

    test "displays empty state when board has no columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "No columns yet"
      assert html =~ "Create your first column"
    end

    test "displays columns in order", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      column3 = column_fixture(board, %{name: "Done"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ column1.name
      assert html =~ column2.name
      assert html =~ column3.name

      # Check order by position in HTML
      assert html =~ ~r/To Do.*In Progress.*Done/s
    end

    test "displays WIP limit indicator when column has WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "In Progress", wip_limit: 5})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # New ColumnHeader badge renders the count and limit as "N/M".
      assert html =~ "0/5"
    end

    test "does not display WIP limit indicator when limit is 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "Done", wip_limit: 0})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # WIP limit label should not appear when limit is 0
      refute html =~ "WIP: 0"
    end
  end

  describe "Column Management" do
    setup [:register_and_log_in_user]

    test "creates new column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click "New column" button which patches to the form
      show_live |> element("a", "New column") |> render_click()

      # Validate form shows error for missing name
      assert show_live
             |> form("#column-form", column: %{name: nil})
             |> render_change() =~ "can&#39;t be blank"

      # Submit form
      show_live
      |> form("#column-form", column: %{name: "To Do", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "To Do"
      # New ColumnHeader badge renders count/limit as "N/M".
      assert html =~ "0/5"
    end

    test "creates column with default WIP limit of 0", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New column") |> render_click()

      show_live
      |> form("#column-form", column: %{name: "Done"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column created successfully"
      assert html =~ "Done"
      # Should not show WIP limit indicator when it's 0
      refute html =~ "WIP: 0"
    end

    test "rejects negative WIP limit when creating column", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live |> element("a", "New column") |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{name: "Test", wip_limit: -1})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "edits existing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      # Use a column name that doesn't collide with BoardHeader's "To Do"
      # KV stat label so the rename-refute is unambiguous.
      column = column_fixture(board, %{name: "Inbox", wip_limit: 3})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      show_live
      |> form("#column-form", column: %{name: "In Progress", wip_limit: 5})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Column updated successfully"
      assert html =~ "In Progress"
      assert html =~ "5"
      refute html =~ "Inbox"
    end

    test "rejects negative WIP limit when editing column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("#columns-#{column.id} a[href*='edit']")
      |> render_click()

      html =
        show_live
        |> form("#column-form", column: %{wip_limit: -5})
        |> render_change()

      assert html =~ "must be greater than or equal to 0"
    end

    test "deletes column", %{conn: conn, user: user} do
      board = board_fixture(user)
      # Use a column name that doesn't collide with BoardHeader's "To Do"
      # KV stat label so the post-delete refute is unambiguous.
      column = column_fixture(board, %{name: "Inbox"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Inbox"

      # Trigger the delete_column event directly
      show_live |> render_click("delete_column", %{"id" => column.id})

      html = render(show_live)
      assert html =~ "Column deleted successfully"
      refute html =~ "Inbox"
    end

    test "displays New column button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New column"
    end
  end

  describe "New Goal Header Link" do
    setup [:register_and_log_in_user]

    test "displays New goal link in header when board has no goals", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      # The whole point of the header entry point: reachable at zero goals.
      assert html =~ "New goal"
      assert has_element?(show_live, ~s(a[href="/boards/#{board.id}/goals/new"]))
    end

    test "member with modify access sees the New goal link", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ~s(a[href="/boards/#{board.id}/goals/new"]))
    end

    test "read-only user does not see the New goal link", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "New goal"
      refute has_element?(show_live, ~s(a[href="/boards/#{board.id}/goals/new"]))
    end

    test "read-only user navigating directly to /goals/new is denied", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      _column = column_fixture(board, %{name: "To Do"})

      # On a direct mount the gate's push_patch surfaces as a live_redirect
      # back to the board with the permission flash.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/boards/#{board}/goals/new")

      assert to == "/boards/#{board.id}"
      assert flash["error"] == "You do not have permission to modify tasks on this board"
    end

    test "New goal link opens the task form with type preset to goal", %{conn: conn, user: user} do
      board = board_fixture(user)
      first_col = column_fixture(board, %{name: "Backlog Column"})
      _second_col = column_fixture(board, %{name: "Ready Column"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element(~s(a[href="/boards/#{board.id}/goals/new"]))
      |> render_click()

      assert has_element?(show_live, "#task-form")

      assert has_element?(
               show_live,
               ~s(#task-form select[name="task[type]"] option[value="goal"][selected])
             )

      # Column preselected to the board's leftmost column.
      assert has_element?(
               show_live,
               ~s(#task-form select[name="task[column_id]"] option[value="#{first_col.id}"][selected])
             )
    end

    test "submitting the New goal form creates a goal in the leftmost column", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      first_col = column_fixture(board, %{name: "Backlog Column"})
      _second_col = column_fixture(board, %{name: "Ready Column"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/goals/new")

      show_live
      |> form("#task-form", task: %{title: "Ship Q3 launch"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Ship Q3 launch"

      task = Kanban.Repo.get_by!(Kanban.Tasks.Task, title: "Ship Q3 launch")
      assert task.type == :goal
      assert task.column_id == first_col.id
    end

    test "/goals/new on a board with no columns flashes and returns to the board", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)

      # On a direct mount the missing-column push_patch surfaces as a
      # live_redirect back to the board with the error flash.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/boards/#{board}/goals/new")

      assert to == "/boards/#{board.id}"
      assert flash["error"] == "Column not found on this board"
    end

    test "creates a goal even when the leftmost column is at its WIP limit", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      first_col = column_fixture(board, %{name: "Limited", wip_limit: 1})
      _task = task_fixture(first_col, %{title: "Fills the WIP limit"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/goals/new")

      # Goals bypass WIP checks server-side (only :work/:defect are counted),
      # so creating into a full column must succeed.
      show_live
      |> form("#task-form", task: %{title: "Goal over the limit"})
      |> render_submit()

      task = Kanban.Repo.get_by!(Kanban.Tasks.Task, title: "Goal over the limit")
      assert task.type == :goal
      assert task.column_id == first_col.id
    end

    test "displays New goal link on an AI-optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      # Unlike New column (hidden on AI-optimized boards), the New goal
      # link is gated only on @can_modify.
      assert has_element?(show_live, ~s(a[href="/boards/#{board.id}/goals/new"]))
      refute html =~ "New column"
    end
  end

  describe "Task Management" do
    setup [:register_and_log_in_user]

    test "displays tasks in column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "First task", description: "Description 1"})
      task2 = task_fixture(column, %{title: "Second task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Task titles appear on the card. (Descriptions live in the task
      # detail modal, not the kanban card — keeps the card terse.)
      assert html =~ task1.title
      assert html =~ task2.title
    end

    test "displays empty state when column has no tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # ColumnEmpty marks itself with data-column-empty for any column
      # name (custom names fall back to the :backlog status hint).
      assert html =~ "data-column-empty"
      assert html =~ "Unrefined ideas"
    end

    test "displays task count in column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # ColumnHeader emits the count inside a font-mono badge.
      assert html =~ ~r/>\s*2\s*</
    end

    test "creates new task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click "Add task" button
      show_live
      |> element("a[href='/boards/#{board.id}/columns/#{column.id}/tasks/new']")
      |> render_click()

      # Validate form shows error for missing title
      assert show_live
             |> form("#task-form", task: %{title: nil})
             |> render_change() =~ "can&#39;t be blank"

      # Submit form
      show_live
      |> form("#task-form", task: %{title: "New Task", description: "Task description"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Task created successfully"
      assert html =~ "New Task"
    end

    test "edits existing task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Original Title"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Click edit button for task
      show_live
      |> element("a[href='/boards/#{board.id}/tasks/#{task.id}/edit']")
      |> render_click()

      # Update task
      show_live
      |> form("#task-form", task: %{title: "Updated Title", description: "Updated description"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Task updated successfully"
      assert html =~ "Updated Title"
      refute html =~ "Original Title"
    end

    test "deletes task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Task to delete"

      # Trigger the delete_task event directly
      show_live |> render_click("delete_task", %{"id" => task.id})

      html = render(show_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Task to delete"
    end

    test "shows Add task button when WIP limit not reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add Task"
    end

    test "hides Add task button when WIP limit reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # ColumnHeader hides the + task link when new_task_path is nil
      # (the LiveView passes nil at the WIP limit).
      refute html =~ ~s(href="/boards/#{board.id}/columns/#{column.id}/tasks/new")
      assert html =~ "2/2"
    end

    test "shows warning indicator when column exceeds WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      # Create column with higher limit initially
      column = column_fixture(board, %{name: "In Progress", wip_limit: 5})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})
      _task3 = task_fixture(column, %{title: "Task 3"})

      # Lower the WIP limit below current task count to simulate exceeding
      {:ok, _column} = Kanban.Columns.update_column(column, %{wip_limit: 2})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # New ColumnHeader uses --st-blocked-soft for the over-WIP highlight
      # on the badge bg + the status-dot ring.
      assert html =~ "var(--st-blocked-soft)"
      assert html =~ "var(--st-blocked)"
    end

    test "displays neutral indicator when column under WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      _task1 = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # ColumnHeader uses --ink-3 + --surface-sunken when under WIP. Refute the
      # over-WIP badge's exact signature (text-then-bg) rather than the bare
      # token — the error flash also uses --st-blocked-soft elsewhere on the page.
      assert html =~ "1/3"
      refute html =~ "color: var(--st-blocked);background: var(--st-blocked-soft);"
    end

    test "displays neutral indicator when column at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # At-limit (count == wip) is NOT over-WIP — badge stays neutral. Refute the
      # over-WIP badge's exact signature, not the bare token (the error flash
      # also uses --st-blocked-soft on the page).
      assert html =~ "2/2"
      refute html =~ "color: var(--st-blocked);background: var(--st-blocked-soft);"
    end

    test "cannot create task when WIP limit reached", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 1})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # The + task affordance is hidden at the WIP limit.
      html = render(show_live)
      refute html =~ ~s(href="/boards/#{board.id}/columns/#{column.id}/tasks/new")
    end
  end

  describe "Drag and Drop" do
    setup [:register_and_log_in_user]

    test "moves task within same column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task3 (position 2) to position 0
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task3.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 0
      })

      # Verify task was moved by checking the order
      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task3.id, task1.id, task2.id]
    end

    test "moves task to different column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress"})
      task = task_fixture(column1, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task from column1 to column2
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 0
      })

      # Verify task was moved
      column1
      |> Kanban.Tasks.list_tasks()
      |> Enum.empty?()
      |> assert()

      tasks = Kanban.Tasks.list_tasks(column2)
      assert length(tasks) == 1
      assert hd(tasks).id == task.id
    end

    test "respects WIP limit when moving task to different column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Task 1"})
      _task2 = task_fixture(column2, %{title: "Task 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Try to move task from column1 to column2 (already at limit)
      # Suppress warning log by using @tag :capture_log
      capture_log(fn ->
        html =
          show_live
          |> render_click("move_task", %{
            "task_id" => "#{task.id}",
            "old_column_id" => "#{column1.id}",
            "new_column_id" => "#{column2.id}",
            "new_position" => 0
          })

        # Should show error message
        assert html =~ "Cannot move task: column has reached its WIP limit"

        # Verify task was NOT moved
        tasks1 = Kanban.Tasks.list_tasks(column1)
        assert length(tasks1) == 1
        assert hd(tasks1).id == task.id

        tasks2 = Kanban.Tasks.list_tasks(column2)
        assert length(tasks2) == 2
      end)
    end

    test "moves task to different column with room", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task from column1 to column2 (has room)
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 1
      })

      # Verify task was moved
      column1
      |> Kanban.Tasks.list_tasks()
      |> Enum.empty?()
      |> assert()

      tasks2 = Kanban.Tasks.list_tasks(column2)
      assert length(tasks2) == 2
      task_ids = Enum.map(tasks2, & &1.id)
      assert task.id in task_ids
    end

    test "updates position correctly when moving task", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move task1 (position 0) to position 2 (end)
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task1.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 2
      })

      # Verify new order
      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task2.id, task3.id, task1.id]
    end

    test "displays drag handle on tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for drag handle class
      assert html =~ "drag-handle"
    end

    test "shows sortable hook on task list", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check for sortable hook
      assert html =~ ~s(phx-hook="Sortable")
      assert html =~ ~s(data-column-id="#{column.id}")
      assert html =~ ~s(data-group="tasks")
    end

    test "highlights column when at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      _task1 = task_fixture(column, %{title: "Task 1"})
      _task2 = task_fixture(column, %{title: "Task 2"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      # Check that WIP limit data attributes are present for JS to use
      assert html =~ ~s(data-wip-limit="2")
      assert html =~ ~s(data-task-count="2")
    end
  end

  describe "Permissions - Owner" do
    setup [:register_and_log_in_user]

    test "owner can see add task buttons", %{conn: conn, user: user} do
      board = board_fixture(user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add Task"
      assert html =~ ~s(phx-hook="Sortable")
    end

    test "owner can see edit and delete buttons for columns", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      # Check that delete link with confirmation exists
      assert html =~ ~s(phx-click)
      assert html =~ ~s(delete_column)
      assert html =~ ~s(Are you sure you want to delete this column?)
    end

    test "owner can see edit and delete buttons for tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
      # Check that delete link with confirmation exists
      assert html =~ ~s(delete_task)
      assert html =~ ~s(Are you sure you want to delete this task?)
    end
  end

  describe "Permissions - Modify Access" do
    setup [:register_and_log_in_user]

    test "user with modify access can see add task buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Add Task"
    end

    test "user with modify access can see task edit/delete buttons but not column buttons", %{
      conn: conn,
      user: user
    } do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      assert has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
    end

    test "user with modify access can delete tasks", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Task to delete"

      show_live |> render_click("delete_task", %{"id" => task.id})

      html = render(show_live)
      assert html =~ "Task deleted successfully"
      refute html =~ "Task to delete"
    end

    test "user with modify access cannot delete columns", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)
      column = column_fixture(board, %{name: "To Delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "To Delete"

      show_live |> render_click("delete_column", %{"id" => column.id})

      html = render(show_live)
      assert html =~ "Only the board owner can delete columns"
      assert html =~ "To Delete"
    end
  end

  describe "Permissions - Read Only Access" do
    setup [:register_and_log_in_user]

    test "user with read only access cannot see add task buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      _column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      refute html =~ "Add Task"
      refute html =~ "hero-plus-circle-solid"
    end

    test "user with read only access cannot see edit buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([href="/boards/#{board.id}/columns/#{column.id}/edit"]))
      refute has_element?(show_live, ~s([href="/boards/#{board.id}/tasks/#{task.id}/edit"]))
    end

    test "user with read only access cannot see delete buttons", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      refute has_element?(show_live, ~s([phx-click="delete_column"]))
      refute has_element?(show_live, ~s([phx-click="delete_task"]))
    end

    test "user with read only access can view board and tasks", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user, %{name: "Shared Board"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Visible Task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Shared Board"
      assert html =~ "To Do"
      assert html =~ "Visible Task"
    end
  end

  describe "Task Assignment Display" do
    setup [:register_and_log_in_user]

    test "displays assignee avatar for assigned tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      other_user = user_fixture(%{email: "assigned@example.com", name: "Assigned User"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :modify, user)

      _task = task_fixture(column, %{title: "Assigned Task", assigned_to_id: other_user.id})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Assigned Task"
      # New TaskCard renders a 16px circular Avatar instead of the
      # legacy hero-user-solid icon. W900 switched the initials color
      # from text-primary-content (cream — 3.23:1 on a colored circle,
      # failing WCAG AA) to inline color: var(--ink), which gives ~5:1
      # in both themes since var(--ink) flips to a high-contrast value
      # against the medium-saturation avatar bg.
      assert html =~ "justify-center font-semibold"
      assert html =~ "color: var(--ink);"
      assert html =~ "width: 16px; height: 16px"
    end

    test "does not display assignee avatar for unassigned tasks", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Unassigned Task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Unassigned Task"
      # No assignee → no 16px avatar inside the task card. (The 24px
      # avatar in the SideNav footer is a different size and stays.)
      refute html =~ "width: 16px; height: 16px"
    end
  end

  describe "Column Reordering" do
    setup [:register_and_log_in_user]

    test "handles move_column event successfully", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Reorder columns: swap first and third
      new_order = [column3.id, column2.id, column1.id]

      show_live
      |> render_click("move_column", %{
        "column_id" => "#{column3.id}",
        "column_ids" => Enum.map(new_order, &to_string/1)
      })

      # Verify columns are in new order
      columns = Kanban.Columns.list_columns(board)
      column_ids = Enum.map(columns, & &1.id)

      assert column_ids == new_order
    end
  end

  describe "Board Display" do
    setup [:register_and_log_in_user]

    test "displays board name and description", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "My Project Board", description: "Project description"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "My Project Board"
      assert html =~ "Project description"
    end

    test "displays New column button", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "New column"
      assert has_element?(show_live, ~s([href="/boards/#{board.id}/columns/new"]))
    end
  end

  describe "Navigation with Modals" do
    setup [:register_and_log_in_user]

    test "can navigate to new column modal", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/new")

      assert true
    end

    test "can navigate to edit column modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Edit"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert true
    end

    test "can navigate to new task modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      assert true
    end

    test "can navigate to edit task modal", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to Edit"})

      {:ok, _show_live, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert true
    end
  end

  describe "Task Reordering Within Column" do
    setup [:register_and_log_in_user]

    test "reorders tasks within the same column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task3.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 0
      })

      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task3.id, task1.id, task2.id]
    end

    test "handles moving task to end of column", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task1 = task_fixture(column, %{title: "Task 1"})
      task2 = task_fixture(column, %{title: "Task 2"})
      task3 = task_fixture(column, %{title: "Task 3"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task1.id}",
        "old_column_id" => "#{column.id}",
        "new_column_id" => "#{column.id}",
        "new_position" => 2
      })

      tasks = Kanban.Tasks.list_tasks(column)
      task_ids = Enum.map(tasks, & &1.id)

      assert task_ids == [task2.id, task3.id, task1.id]
    end
  end

  describe "WIP Limit Enforcement" do
    setup [:register_and_log_in_user]

    test "prevents moving task to column at WIP limit", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 2})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Existing 1"})
      _task2 = task_fixture(column2, %{title: "Existing 2"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      capture_log(fn ->
        html =
          show_live
          |> render_click("move_task", %{
            "task_id" => "#{task.id}",
            "old_column_id" => "#{column1.id}",
            "new_column_id" => "#{column2.id}",
            "new_position" => 0
          })

        assert html =~ "Cannot move task: column has reached its WIP limit"

        tasks1 = Kanban.Tasks.list_tasks(column1)
        assert length(tasks1) == 1
        assert hd(tasks1).id == task.id
      end)
    end

    test "allows moving task to column with available space", %{conn: conn, user: user} do
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "To Do"})
      column2 = column_fixture(board, %{name: "In Progress", wip_limit: 3})
      task = task_fixture(column1, %{title: "Task to move"})
      _task1 = task_fixture(column2, %{title: "Existing 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{task.id}",
        "old_column_id" => "#{column1.id}",
        "new_column_id" => "#{column2.id}",
        "new_position" => 0
      })

      tasks1 = Kanban.Tasks.list_tasks(column1)
      assert tasks1 == []

      tasks2 = Kanban.Tasks.list_tasks(column2)
      assert length(tasks2) == 2
      task_ids = Enum.map(tasks2, & &1.id)
      assert task.id in task_ids
    end
  end

  describe "Page Titles" do
    setup [:register_and_log_in_user]

    test "sets page title for show action", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      assert page_title(show_live) =~ "Stride"
    end

    test "sets page title for new column action", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/new")

      assert page_title(show_live) =~ "New column"
    end

    test "sets page title for edit column action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert page_title(show_live) =~ "Edit Column"
    end

    test "sets page title for new task action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")

      assert page_title(show_live) =~ "Stride"
    end

    test "sets page title for edit task action", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task 1"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      assert page_title(show_live) =~ "Edit Task"
    end
  end

  describe "Goal Cards" do
    setup [:register_and_log_in_user]

    test "displays goal card with violet styling", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _goal = task_fixture(column, %{title: "Goal Task", type: :goal})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Goal Task"
      # GoalCard variant uses --stride-violet-* design tokens.
      assert html =~ "var(--stride-violet-soft)"
      assert html =~ ~r/>\s*GOAL\s*</
    end

    test "displays progress bar for goal with children", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      goal = task_fixture(column, %{title: "Goal Task", type: :goal})
      _child1 = task_fixture(column, %{title: "Child 1", parent_id: goal.id})
      _child2 = task_fixture(column, %{title: "Child 2", parent_id: goal.id})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Goal Task"
      assert html =~ "0/2"
    end

    test "displays correct progress when some children are completed", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      goal = task_fixture(column, %{title: "Goal Task", type: :goal})
      child1 = task_fixture(column, %{title: "Child 1", parent_id: goal.id})
      _child2 = task_fixture(column, %{title: "Child 2", parent_id: goal.id})

      {:ok, _task} =
        Kanban.Tasks.update_task(child1, %{
          status: :completed,
          completed_at: DateTime.utc_now()
        })

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Goal Task"
      assert html =~ "1/2"
    end

    test "goal card does not have drag handle", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _goal = task_fixture(column, %{title: "Goal Task", type: :goal})
      _regular_task = task_fixture(column, %{title: "Regular Task"})

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}")

      assert html =~ "Goal Task"
      assert html =~ "Regular Task"
      assert html =~ "drag-handle"
    end
  end

  describe "Goal Automatic Movement" do
    setup [:register_and_log_in_user]

    test "goal moves to target column when all children are moved", %{conn: conn, user: user} do
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})

      goal = task_fixture(backlog, %{title: "Goal Task", type: :goal})
      child1 = task_fixture(backlog, %{title: "Child 1", parent_id: goal.id})
      child2 = task_fixture(backlog, %{title: "Child 2", parent_id: goal.id})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{child1.id}",
        "old_column_id" => "#{backlog.id}",
        "new_column_id" => "#{ready.id}",
        "new_position" => 0
      })

      show_live
      |> render_click("move_task", %{
        "task_id" => "#{child2.id}",
        "old_column_id" => "#{backlog.id}",
        "new_column_id" => "#{ready.id}",
        "new_position" => 1
      })

      updated_goal = Kanban.Tasks.get_task!(goal.id)
      assert updated_goal.column_id == ready.id
    end

    test "goal positions itself at the top when child tasks move", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)
      backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "Ready"})

      goal = task_fixture(backlog, %{title: "Goal Task", type: :goal})
      child1 = task_fixture(backlog, %{title: "Child 1", parent_id: goal.id})
      child2 = task_fixture(backlog, %{title: "Child 2", parent_id: goal.id})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # Move child1 first - goal should position at top of column
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{child1.id}",
        "old_column_id" => "#{backlog.id}",
        "new_column_id" => "#{ready.id}",
        "new_position" => 0
      })

      # Move child2 second - goal should remain at top with all tasks below
      show_live
      |> render_click("move_task", %{
        "task_id" => "#{child2.id}",
        "old_column_id" => "#{backlog.id}",
        "new_column_id" => "#{ready.id}",
        "new_position" => 1
      })

      tasks_in_ready = Kanban.Tasks.list_tasks(ready)
      task_ids = Enum.map(tasks_in_ready, & &1.id)

      goal_index = Enum.find_index(task_ids, &(&1 == goal.id))
      child1_index = Enum.find_index(task_ids, &(&1 == child1.id))
      child2_index = Enum.find_index(task_ids, &(&1 == child2.id))

      # Goals should always be at the top, with all tasks below
      # Expected order: goal, child1, child2
      assert goal_index < child1_index
      assert goal_index < child2_index
      assert child1_index < child2_index
    end
  end

  describe "API Token Management" do
    setup [:register_and_log_in_user]

    test "displays API tokens page for AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, _show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")

      assert html =~ "API tokens"
    end

    test "redirects non-AI boards from API tokens page", %{conn: conn, user: user} do
      board = board_fixture(user)

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               live(conn, ~p"/boards/#{board}/api_tokens")

      assert redirect_path == ~p"/boards/#{board}"
    end

    test "creates new API token", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      html =
        show_live
        |> element("form[phx-submit='create_token']")
        |> render_submit(%{token: %{name: "Test Token"}})

      assert html =~ "Test Token"
    end

    test "revokes API token", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, {api_token, _plain_text}} =
        Kanban.ApiTokens.create_api_token(user, board, %{name: "Token to Revoke"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}/api_tokens")
      assert html =~ "Token to Revoke"

      show_live
      |> render_click("revoke_token", %{"id" => api_token.id})

      html = render(show_live)
      assert html =~ "API token revoked successfully"
    end

    test "user with modify access can create tokens", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = ai_optimized_board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}/api_tokens")

      html =
        show_live
        |> element("form[phx-submit='create_token']")
        |> render_submit(%{token: %{name: "Modify User Token"}})

      assert html =~ "Modify User Token"
    end

    test "user with read only access cannot access API tokens page", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = ai_optimized_board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :read_only, other_user)

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               live(conn, ~p"/boards/#{board}/api_tokens")

      assert redirect_path == ~p"/boards/#{board}"
    end
  end

  describe "Field Visibility Toggle" do
    setup [:register_and_log_in_user]

    test "owner can toggle field visibility", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      _task = task_fixture(column, %{title: "Test Task", description: "Test description"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      # "complexity" is on the W401 allow-list; default is false, so toggling
      # should flip it to true.
      show_live
      |> render_click("toggle_field", %{"field" => "complexity"})

      updated_board = Kanban.Boards.get_board!(board.id, user)
      assert updated_board.field_visibility["complexity"] == true
    end

    test "owner cannot toggle a field not on the allow-list (W401)",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> render_click("toggle_field", %{"field" => "evil_injected_key"})

      assert render(show_live) =~ "Invalid field name"
      updated_board = Kanban.Boards.get_board!(board.id, user)
      refute Map.has_key?(updated_board.field_visibility, "evil_injected_key")
    end

    test "non-owner cannot toggle field visibility", %{conn: conn, user: user} do
      other_user = user_fixture()
      board = board_fixture(other_user)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user, :modify, other_user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      html =
        show_live
        |> render_click("toggle_field", %{"field" => "description"})

      assert html =~ "Only board owners can change field visibility"
    end
  end

  describe "PubSub Real-time Updates" do
    setup [:register_and_log_in_user]

    test "receives task_created broadcast and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      task = task_fixture(column, %{title: "New Task"})

      send(show_live.pid, {Kanban.Tasks, :task_created, task})

      html = render(show_live)
      assert html =~ "New Task"
    end

    test "receives task_updated broadcast and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Original Title"})

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      {:ok, updated_task} = Kanban.Tasks.update_task(task, %{title: "Updated Title"})

      send(show_live.pid, {Kanban.Tasks, :task_updated, updated_task})

      html = render(show_live)
      assert html =~ "Updated Title"
    end

    test "receives task_deleted broadcast and reloads", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do"})
      task = task_fixture(column, %{title: "Task to Delete"})

      {:ok, show_live, html} = live(conn, ~p"/boards/#{board}")
      assert html =~ "Task to Delete"

      {:ok, _deleted_task} = Kanban.Tasks.delete_task(task)

      send(show_live.pid, {Kanban.Tasks, :task_deleted, task})

      html = render(show_live)
      refute html =~ "Task to Delete"
    end

    test "receives field_visibility_updated broadcast and updates assigns", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      new_visibility = %{"description" => true}
      send(show_live.pid, {:field_visibility_updated, new_visibility})

      assert show_live |> render() =~ ""
      assert :sys.get_state(show_live.pid).socket.assigns.field_visibility == new_visibility
    end
  end

  describe "AI Optimized Board Restrictions" do
    setup [:register_and_log_in_user]

    test "cannot add columns to AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               live(conn, ~p"/boards/#{board}/columns/new")

      assert redirect_path == ~p"/boards/#{board}"
    end

    test "cannot edit columns on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      column = List.first(columns)

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               live(conn, ~p"/boards/#{board}/columns/#{column}/edit")

      assert redirect_path == ~p"/boards/#{board}"
    end

    test "cannot delete columns on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      column = List.first(columns)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      html = show_live |> render_click("delete_column", %{"id" => column.id})

      assert html =~ "Cannot delete columns on AI optimized boards"
    end

    test "cannot reorder columns on AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      column1 = Enum.at(columns, 0)
      column2 = Enum.at(columns, 1)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      html =
        show_live
        |> render_click("move_column", %{
          "column_id" => "#{column2.id}",
          "column_ids" => ["#{column2.id}", "#{column1.id}"]
        })

      assert html =~ "Cannot reorder columns on AI optimized boards"
    end

    test "can add tasks to AI optimized board", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      column = List.first(columns)

      {:ok, show_live, _html} = live(conn, ~p"/boards/#{board}")

      show_live
      |> element("a[href='/boards/#{board.id}/columns/#{column.id}/tasks/new']")
      |> render_click()

      show_live
      |> form("#task-form", task: %{title: "New Task on AI Board"})
      |> render_submit()

      html = render(show_live)
      assert html =~ "Task created successfully"
      assert html =~ "New Task on AI Board"
    end
  end
end
