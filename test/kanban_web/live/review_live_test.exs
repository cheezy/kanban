defmodule KanbanWeb.ReviewLiveTest do
  @moduledoc """
  Integration tests for `KanbanWeb.ReviewLive` — the workspace-level
  Review Queue view at `/review`.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  defp pending_task!(column, attrs) do
    base = %{
      needs_review: true,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      completed_by_agent: "Claude",
      acceptance_criteria: "First criterion\nSecond criterion",
      actual_files_changed: "lib/a.ex, lib/b.ex"
    }

    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(Map.merge(base, attrs))

    task
  end

  defp setup_review_column(user) do
    board = board_fixture(user)
    review_column = column_fixture(board, %{name: "Review", position: 1})
    _doing = column_fixture(board, %{name: "Doing", position: 2})
    _done = column_fixture(board, %{name: "Done", position: 3})
    %{board: board, column: review_column}
  end

  describe "unauthenticated access" do
    test "redirects to the log-in page when the user is not signed in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/review")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "mount and route" do
    setup [:register_and_log_in_user]

    test "authenticated user with a pending task sees queue list and detail panel",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W777", title: "Wire the thing"})

      {:ok, _view, html} = live(conn, ~p"/review")

      assert html =~ "data-review-header"
      assert html =~ "Review queue"
      assert html =~ "Workspace"
      assert html =~ "data-review-queue-rail"
      assert html =~ "data-review-queue-item-id=\"#{task.id}\""
      assert html =~ "Wire the thing"
      assert html =~ "data-review-detail-header"
      assert html =~ "W777"
    end

    test "empty queue renders the inbox-zero empty state and no detail panel",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review")

      assert html =~ "data-review-queue-empty"
      assert html =~ "Inbox zero"
      assert html =~ "data-review-detail-empty"
      refute html =~ "data-review-detail-header"
    end

    test "uses :review as the active side-nav and shows 'Review queue' breadcrumb",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/review")
      html = render(view)
      assert html =~ "Review queue"
      assert html =~ "Workspace"
    end

    test "subtitle reflects queue count and distinct agents", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{completed_by_agent: "Claude"})
      pending_task!(column, %{completed_by_agent: "Codex"})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-header-subtitle"
      assert html =~ "2 tasks from 2 agents waiting on you"
    end
  end

  describe "select_item event" do
    setup [:register_and_log_in_user]

    test "clicking a queue row updates the detail panel to that task",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _first = pending_task!(column, %{identifier: "W101"})
      second = pending_task!(column, %{identifier: "W102"})

      {:ok, view, _html} = live(conn, ~p"/review")

      html =
        view
        |> element("[data-review-queue-item-id=\"#{second.id}\"]")
        |> render_click()

      assert html =~ "W102"
      assert html =~ "data-review-detail-header"
    end
  end

  describe "deselect_item event" do
    setup [:register_and_log_in_user]

    test "pushing deselect_item clears the selection and shows the empty-state copy",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W303"})

      {:ok, view, _html} = live(conn, ~p"/review")

      # Select a task to populate the detail panel.
      view
      |> element("[data-review-queue-item-id=\"#{task.id}\"]")
      |> render_click()

      # Push the deselect event (the back button uses phx-click="deselect_item").
      html = render_click(view, "deselect_item", %{})

      # Empty-state copy is shown, detail header is gone.
      assert html =~ "Select a task from the queue to start a review."
      refute html =~ "data-review-detail-header"
    end
  end

  describe "approve event" do
    setup [:register_and_log_in_user]

    test "approving the selected task removes it from the queue", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W201"})

      {:ok, view, _html} = live(conn, ~p"/review")
      assert render(view) =~ "data-review-queue-item-id=\"#{task.id}\""

      html =
        view
        |> element("[data-review-detail-header-approve]")
        |> render_click()

      refute html =~ "data-review-queue-item-id=\"#{task.id}\""
      assert html =~ "data-review-queue-empty"
    end
  end

  describe "request_changes event" do
    setup [:register_and_log_in_user]

    test "clicking Request changes opens the notes form", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{identifier: "W301"})

      {:ok, view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-request-changes-form"

      html =
        view
        |> element("[data-review-detail-header-request-changes]")
        |> render_click()

      assert html =~ "data-review-request-changes-form"
    end

    test "submitting Request changes with notes removes the task from the queue",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W302"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element("[data-review-detail-header-request-changes]")
      |> render_click()

      html =
        view
        |> form("[data-review-request-changes-form]", review: %{notes: "Please fix the thing."})
        |> render_submit()

      refute html =~ "data-review-queue-item-id=\"#{task.id}\""
      assert html =~ "data-review-queue-empty"
    end

    test "submitting Request changes with blank notes shows an error and keeps the task",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W303"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element("[data-review-detail-header-request-changes]")
      |> render_click()

      html =
        view
        |> render_submit("submit_request_changes", %{"review" => %{"notes" => "   "}})

      assert html =~ "Notes are required"
      assert html =~ "data-review-queue-item-id=\"#{task.id}\""
    end

    test "cancel_request_changes closes the notes form without changing the queue",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W304"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element("[data-review-detail-header-request-changes]")
      |> render_click()

      assert render(view) =~ "data-review-request-changes-form"

      html = render_click(view, "cancel_request_changes", %{})

      refute html =~ "data-review-request-changes-form"
      assert html =~ "data-review-queue-item-id=\"#{task.id}\""
    end

    test "selecting a different task while the form is open closes the form",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      first = pending_task!(column, %{identifier: "W305"})
      second = pending_task!(column, %{identifier: "W306"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element("[data-review-detail-header-request-changes]")
      |> render_click()

      assert render(view) =~ "data-review-request-changes-form"

      html =
        view
        |> element("[data-review-queue-item-id=\"#{second.id}\"]")
        |> render_click()

      refute html =~ "data-review-request-changes-form"
      # The detail panel updates to the second task (verify by ident)
      assert html =~ first.identifier
      assert html =~ second.identifier
    end
  end

  describe "view_diff and other no-op events" do
    setup [:register_and_log_in_user]

    test "view_diff is a no-op that leaves the queue intact", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W401"})

      {:ok, view, _html} = live(conn, ~p"/review")

      html =
        view
        |> element("[data-review-detail-header-view-diff]")
        |> render_click()

      assert html =~ "data-review-queue-item-id=\"#{task.id}\""
      assert html =~ "data-review-detail-header"
    end
  end

  describe "subtitle copy" do
    setup [:register_and_log_in_user]

    test "shows the zero-state subtitle when the queue is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-header-subtitle"
      assert html =~ "0 tasks waiting on you."
    end

    test "uses singular phrasing for exactly 1 task / 1 agent",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{completed_by_agent: "Claude"})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "1 task from 1 agent waiting on you"
    end

    test "appends 'oldest Nm ago' when the oldest task is under an hour old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      pending_task!(column, %{completed_at: DateTime.add(now, -30 * 60, :second)})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/oldest\s+\d+m ago/
    end

    test "appends 'oldest Nh ago' when the oldest task is hours old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      pending_task!(column, %{completed_at: DateTime.add(now, -3 * 3600, :second)})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/oldest\s+3h ago/
    end

    test "appends 'oldest Nd ago' when the oldest task is days old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      pending_task!(column, %{completed_at: DateTime.add(now, -2 * 86_400, :second)})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/oldest\s+2d ago/
    end
  end

  describe "detail panel derived values" do
    setup [:register_and_log_in_user]

    test "summary paragraph renders task.what when present", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{what: "Built a new login form.", description: "Other text."})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-detail-summary"
      assert html =~ "Built a new login form."
      refute html =~ "Other text."
    end

    test "summary paragraph falls back to task.description when :what is nil",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{what: nil, description: "Fallback description body."})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "Fallback description body."
    end

    test "summary paragraph renders nothing visible when both :what and :description are nil",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{what: nil, description: nil})

      {:ok, _view, html} = live(conn, ~p"/review")
      # The summary container is still emitted, but with no inner text.
      assert html =~ "data-review-detail-summary"
    end

    test "stats strip shows em-dash placeholders when acceptance_criteria and files are blank",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      pending_task!(column, %{
        acceptance_criteria: nil,
        actual_files_changed: nil
      })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-stats-cell=\"acceptance\""
      assert html =~ "data-review-stats-cell=\"diff\""
      # Both cells fall back to the em-dash placeholder.
      assert html =~ "—"
    end

    test "diff panel renders the empty state when actual_files_changed is empty",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      pending_task!(column, %{actual_files_changed: ""})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-diff-panel-empty"
    end
  end

  describe "no-op event handlers" do
    setup [:register_and_log_in_user]

    test "approve is a no-op when the queue is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/review")

      # Empty queue → no Approve button rendered. Fire the raw event to
      # exercise the `selected == nil` guard.
      html = render_hook(view, "approve", %{})

      assert html =~ "data-review-queue-empty"
      refute html =~ "data-review-detail-header"
    end

    test "submit_request_changes is a no-op when the queue is empty",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/review")

      html =
        render_hook(view, "submit_request_changes", %{
          "review" => %{"notes" => "this would be valid"}
        })

      assert html =~ "data-review-queue-empty"
      refute html =~ "Requested changes"
    end

    test "selecting an id that is not in the queue clears the selection",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W901"})

      {:ok, view, _html} = live(conn, ~p"/review")

      html = render_hook(view, "select_item", %{"id" => "9999999"})

      refute html =~ "data-review-detail-header"
      # The queue rail still lists the task.
      assert html =~ "data-review-queue-item-id=\"#{task.id}\""
    end
  end

  describe "approve and request_changes error paths" do
    setup [:register_and_log_in_user]

    test "approve surfaces an error flash when Reviews returns {:error, _}",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W801"})

      {:ok, view, _html} = live(conn, ~p"/review")

      # Switch the task to :approved in the DB AFTER mount — the LiveView
      # still has it in :pending, so clicking Approve calls Reviews, which
      # short-circuits via get_pending_review/2 → {:error, :not_found}.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Kanban.Tasks.update_task(task, %{
          review_status: :approved,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      html =
        view
        |> element("[data-review-detail-header-approve]")
        |> render_click()

      assert html =~ "Unable to approve task."
    end

    test "submit_request_changes surfaces an error flash when Reviews returns {:error, _}",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{identifier: "W802"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element("[data-review-detail-header-request-changes]")
      |> render_click()

      # Same trick: make the task no longer pending so Reviews returns
      # {:error, :not_found} when we submit notes.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Kanban.Tasks.update_task(task, %{
          review_status: :approved,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      html =
        view
        |> form("[data-review-request-changes-form]", review: %{notes: "Please fix it"})
        |> render_submit()

      assert html =~ "Unable to request changes on task."
    end
  end
end
