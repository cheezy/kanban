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

  # Sets the task's `updated_at` to `seconds_ago` in the past. Used by the
  # subtitle-age tests — `updated_at` is the field `Reviews.queue_stats/1`
  # consults for `oldest_age_minutes`.
  defp backdate_updated_at!(task, seconds_ago) do
    import Ecto.Query

    backdated =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(seconds_ago, :second)
      |> NaiveDateTime.truncate(:second)

    {1, _} =
      from(t in Kanban.Tasks.Task, where: t.id == ^task.id)
      |> Kanban.Repo.update_all(set: [updated_at: backdated])

    %{task | updated_at: backdated}
  end

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

  describe "review diff panel — end-to-end click → render → close flow" do
    setup [:register_and_log_in_user]

    setup do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "diff-panel-e2e-#{inspect(ref)}",
        [
          [:kanban, :review_diff_panel, :opened],
          [:kanban, :review_diff_panel, :closed]
        ],
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry, ref, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("diff-panel-e2e-#{inspect(ref)}") end)
      %{ref: ref}
    end

    test "full flow: text diff renders, binary placeholder renders, telemetry fires open + close",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)

      changed_files = [
        %{
          "path" => "lib/foo.ex",
          "diff" => "--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1,1 +1,1 @@\n-old\n+new\n"
        },
        %{
          "path" => "assets/logo.png",
          "diff" => "[binary file — no diff captured]"
        }
      ]

      task =
        pending_task!(column, %{
          actual_files_changed: "lib/foo.ex, assets/logo.png",
          changed_files: changed_files
        })

      task_id = task.id

      # Dark-mode coverage: every assertion in this block targets data-*
      # markers, not coloring. The +/-, hunk, binary-placeholder, and
      # truncation-notice styles in assets/css/app.css use theme-bound
      # CSS variables (--st-ok-soft, --st-blocked-soft, --ink-*, --line,
      # --stride-orange) — no hardcoded hex/named colors. Switching the
      # data-theme attribute therefore re-themes the panel automatically;
      # the same data-* assertions hold under both themes. Component-level
      # tests in test/kanban_web/components/review_diff_panel_test.exs:53
      # already pin "no hardcoded grey" for the file-row chrome.
      {:ok, view, html} = live(conn, ~p"/review")

      # On mount, no file is selected → no diff content section is rendered.
      refute html =~ "data-review-diff-panel-diff"

      # Click the text-diff file: panel renders in :patch mode with +/- classes.
      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/foo.ex"] button))
        |> render_click()

      assert html =~ ~s(data-review-diff-panel-diff-mode="full")
      assert html =~ ~s(data-diff-line="add")
      assert html =~ ~s(data-diff-line="del")

      # Dark-mode safety: the rendered diff content references only
      # theme tokens, never hardcoded greys or whites that would fail
      # under data-theme="dark".
      refute html =~ "bg-gray-"
      refute html =~ "text-gray-"
      refute html =~ "bg-white"

      # Telemetry fired :opened.
      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _,
                       %{task_id: ^task_id}}

      # Click the binary file: panel renders the binary placeholder, NOT the
      # patch render. No second :opened fires for the same task.
      html =
        view
        |> element(~s([data-review-diff-panel-file-path="assets/logo.png"] button))
        |> render_click()

      assert html =~ ~s(data-review-diff-panel-diff-mode="binary")
      assert html =~ "Binary file changed"
      refute html =~ ~s(data-diff-line="add")

      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}

      # Navigate away (deselect): :closed fires for the task.
      render_click(view, "deselect_item", %{})

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :closed], _,
                       %{task_id: ^task_id}}
    end

    test "legacy payload (no changed_files): click still selects, panel shows 'no diff available', page does not crash",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      # Legacy: older plugin emitted no `changed_files`. The DB default is
      # [] so the field is empty, not nil.
      _task = pending_task!(column, %{actual_files_changed: "lib/legacy.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/legacy.ex"] button))
        |> render_click()

      # Selection succeeded — row marked active.
      assert html =~
               ~s(data-review-diff-panel-file-path="lib/legacy.ex" data-review-diff-panel-file-active="true")

      # Panel renders in :empty mode with the "no diff available" copy.
      assert html =~ ~s(data-review-diff-panel-diff-mode="empty")
      assert html =~ "No diff available for this file."

      # Page did not crash — header still present.
      assert html =~ "data-review-detail-header"
    end

    test "mixed-payload edge case: task with diff data for some files, missing for others",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      changed_files = [
        %{"path" => "lib/has_diff.ex", "diff" => "+ added\n- removed\n"}
        # Note: lib/no_diff.ex is in actual_files_changed but absent from
        # changed_files. The LiveView falls back to a path-only payload.
      ]

      _task =
        pending_task!(column, %{
          actual_files_changed: "lib/has_diff.ex, lib/no_diff.ex",
          changed_files: changed_files
        })

      {:ok, view, _html} = live(conn, ~p"/review")

      # File with diff data renders the patch.
      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/has_diff.ex"] button))
        |> render_click()

      assert html =~ ~s(data-review-diff-panel-diff-mode="full")
      assert html =~ ~s(data-diff-line="add")

      # File without diff data falls through to :empty mode.
      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/no_diff.ex"] button))
        |> render_click()

      assert html =~ ~s(data-review-diff-panel-diff-mode="empty")
      assert html =~ "No diff available for this file."
    end

    test "truncated diff with diff_url renders the 'view full diff in repo' link",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      # Pull the truncation marker from the component itself rather than
      # duplicating the literal — both sides share `docs/diff-contract.md`
      # as the source of truth.
      changed_files = [
        %{
          "path" => "lib/big.ex",
          "diff" => "+ a\n+ b\n#{KanbanWeb.ReviewDiffPanel.truncation_marker()}",
          "diff_url" => "https://github.com/example/repo/pull/1/files#diff-abc"
        }
      ]

      _task =
        pending_task!(column, %{
          actual_files_changed: "lib/big.ex",
          changed_files: changed_files
        })

      {:ok, view, _html} = live(conn, ~p"/review")

      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/big.ex"] button))
        |> render_click()

      assert html =~ ~s(data-review-diff-panel-diff-mode="truncated")
      assert html =~ "data-review-diff-panel-diff-link"
      assert html =~ "https://github.com/example/repo/pull/1/files#diff-abc"
    end
  end

  describe "review_diff_panel telemetry" do
    setup [:register_and_log_in_user]

    setup do
      ref = make_ref()
      test_pid = self()

      handler = fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, ref, name, measurements, metadata})
      end

      events = [
        [:kanban, :review_diff_panel, :opened],
        [:kanban, :review_diff_panel, :closed]
      ]

      :telemetry.attach_many("diff-panel-#{inspect(ref)}", events, handler, nil)
      on_exit(fn -> :telemetry.detach("diff-panel-#{inspect(ref)}") end)

      %{ref: ref}
    end

    test "emits :opened the first time a file is selected on a needs_review task",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{actual_files_changed: "lib/a.ex, lib/b.ex"})
      task_id = task.id

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened],
                       %{count: 1, system_time: _}, %{task_id: ^task_id}}
    end

    test "does not re-emit :opened when the same file is clicked twice",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "lib/a.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}
    end

    test "does not re-emit :opened when a different file is clicked on the same task",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "lib/a.ex, lib/b.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}

      view
      |> element(~s([data-review-diff-panel-file-path="lib/b.ex"] button))
      |> render_click()

      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}
    end

    test "emits :closed when the user deselects the task",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{actual_files_changed: "lib/a.ex"})
      task_id = task.id

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      render_click(view, "deselect_item", %{})

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :closed], _,
                       %{task_id: ^task_id}}
    end

    test "emits :closed for the previous task and :opened for the new one when switching tasks",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      first = pending_task!(column, %{identifier: "WT1", actual_files_changed: "lib/a.ex"})
      second = pending_task!(column, %{identifier: "WT2", actual_files_changed: "lib/c.ex"})

      # Queue is ordered by updated_at ascending; second-resolution truncation
      # can collide between two fixtures created in the same tick, so pin the
      # order explicitly.
      first = backdate_updated_at!(first, -60)

      {:ok, view, _html} = live(conn, ~p"/review")

      # First task is auto-selected on mount (oldest in queue).
      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _,
                       %{task_id: id}}

      old_task_id = id

      other = if old_task_id == first.id, do: second, else: first

      view
      |> element("[data-review-queue-item-id=\"#{other.id}\"]")
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :closed], _,
                       %{task_id: ^old_task_id}}

      # No :opened yet — opening fires on file click, not task switch
      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}
    end

    test "emits :closed on LiveView teardown when the panel was open",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{actual_files_changed: "lib/a.ex"})
      task_id = task.id

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      assert_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}

      Process.flag(:trap_exit, true)
      GenServer.stop(view.pid)

      assert_receive {:telemetry, ^ref, [:kanban, :review_diff_panel, :closed], _,
                      %{task_id: ^task_id}},
                     500
    end

    test "emits no events when the user never opens the diff panel",
         %{conn: conn, user: user, ref: ref} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "lib/a.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      render_click(view, "deselect_item", %{})

      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :opened], _, _}
      refute_received {:telemetry, ^ref, [:kanban, :review_diff_panel, :closed], _, _}
    end
  end

  describe "select_changed_file event" do
    setup [:register_and_log_in_user]

    test "clicking a file row sets selected_changed_file and marks that row active",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "lib/a.ex, lib/b.ex"})

      {:ok, view, html} = live(conn, ~p"/review")

      # No file is selected on mount.
      refute html =~ ~s(data-review-diff-panel-file-active="true")

      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
        |> render_click()

      assert html =~
               ~s(data-review-diff-panel-file-path="lib/a.ex" data-review-diff-panel-file-active="true")

      refute html =~
               ~s(data-review-diff-panel-file-path="lib/b.ex" data-review-diff-panel-file-active="true")
    end

    test "clicking a different file moves the active state",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "lib/a.ex, lib/b.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      html =
        view
        |> element(~s([data-review-diff-panel-file-path="lib/b.ex"] button))
        |> render_click()

      assert html =~
               ~s(data-review-diff-panel-file-path="lib/b.ex" data-review-diff-panel-file-active="true")

      refute html =~
               ~s(data-review-diff-panel-file-path="lib/a.ex" data-review-diff-panel-file-active="true")
    end

    test "selecting a different task clears the changed-file selection",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      first = pending_task!(column, %{identifier: "WX1", actual_files_changed: "lib/a.ex"})
      # Backdate so `first` is reliably the oldest and gets selected on mount;
      # otherwise both rows share the same truncated `updated_at` and the
      # head-of-queue selection becomes non-deterministic.
      backdate_updated_at!(first, -60)
      second = pending_task!(column, %{identifier: "WX2", actual_files_changed: "lib/c.ex"})

      {:ok, view, _html} = live(conn, ~p"/review")

      view
      |> element(~s([data-review-diff-panel-file-path="lib/a.ex"] button))
      |> render_click()

      html =
        view
        |> element("[data-review-queue-item-id=\"#{second.id}\"]")
        |> render_click()

      refute html =~ ~s(data-review-diff-panel-file-active="true")
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

  describe "View diff button removal" do
    setup [:register_and_log_in_user]

    test "the View diff button is no longer rendered in the detail header",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{identifier: "W401"})

      {:ok, _view, html} = live(conn, ~p"/review")

      refute html =~ "data-review-detail-header-view-diff"
      refute html =~ "View diff"
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
      task = pending_task!(column, %{})
      backdate_updated_at!(task, -30 * 60)

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/oldest\s+\d+m ago/
    end

    test "appends 'oldest Nh ago' when the oldest task is hours old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{})
      backdate_updated_at!(task, -3 * 3600)

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/oldest\s+3h ago/
    end

    test "appends 'oldest Nd ago' when the oldest task is days old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{})
      backdate_updated_at!(task, -2 * 86_400)

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

  describe "stats strip — Acceptance cell value derivation" do
    setup [:register_and_log_in_user]

    test "renders bare line count when the reviewer subagent was skipped",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          acceptance_criteria: "Crit 1\nCrit 2\nCrit 3",
          reviewer_result: %{"dispatched" => false, "reason" => "small_task_0_1_key_files"}
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-stats-cell="acceptance")
      # No reviewer_result → fallback to total count alone, neutral tone.
      assert html =~ ~r/>\s*3\s*</
      # No "N · X issues" suffix in the Acceptance cell.
      refute html =~ "1 issue"
      refute html =~ "2 issues"
      refute html =~ "3/3"
    end

    test "renders 'N/N' clean value when reviewer dispatched + 0 issues",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          acceptance_criteria: "A\nB\nC\nD",
          reviewer_result: %{
            "dispatched" => true,
            "acceptance_criteria_checked" => 4,
            "issues_found" => 0
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/>\s*4\/4\s*</
    end

    test "renders 'N/N · X issues' when reviewer dispatched + issues found",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          acceptance_criteria: "A\nB\nC\nD",
          reviewer_result: %{
            "dispatched" => true,
            "acceptance_criteria_checked" => 4,
            "issues_found" => 2
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "4/4 · 2 issues"
    end

    test "legacy issues_found > 0 renders a neutral Acceptance tone, not red (D56)",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          acceptance_criteria: "A\nB\nC\nD",
          reviewer_result: %{
            "dispatched" => true,
            "acceptance_criteria_checked" => 4,
            "issues_found" => 2
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      # The informational value still renders…
      assert html =~ "4/4 · 2 issues"
      # …but the Acceptance cell tone must be neutral, never the blocked-red
      # verdict, so it cannot contradict the neutral status pill (D56). Scope
      # strictly to the Acceptance cell (marker → next cell marker) so the
      # assertion is immune to tones elsewhere on the page.
      acceptance_cell =
        html
        |> String.split(~s(data-review-stats-cell="acceptance"))
        |> Enum.at(1, "")
        |> String.split(~s(data-review-stats-cell="tests"))
        |> List.first()

      refute acceptance_cell =~ "var(--st-blocked)"
    end

    test "header issue count reflects displayable issues[] length, not a stale issues_found scalar (D59)",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          acceptance_criteria: "A\nB\nC\nD\nE",
          reviewer_result: %{
            "dispatched" => true,
            "status" => "approved",
            "acceptance_criteria_checked" => 5,
            "issues" => [],
            "issues_found" => 2
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      # issues[] is empty, so the header shows "5/5" — never "5/5 · 2 issues"
      # from the stale scalar issues_found (D59).
      assert html =~ "5/5"
      refute html =~ "· 2 issues"
    end

    test "renders em-dash when no acceptance criteria are recorded",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{acceptance_criteria: nil})

      {:ok, _view, html} = live(conn, ~p"/review")
      # Cell renders the em-dash default when value is nil.
      assert html =~ "—"
    end
  end

  describe "stats strip — Testing strategy + Patterns + Pitfalls cells" do
    setup [:register_and_log_in_user]

    test "Testing strategy reads 'N cases · all present' from the all-present heading",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      report = """
      ## Review Summary

      Approved.

      ### Required test cases (all present)

      - Case one
      - Case two
      - Case three
      """

      _task = pending_task!(column, %{review_report: report})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "3 cases · all present"
    end

    test "Patterns cell reads 'followed' when the Patterns followed section is present",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: "### Patterns followed\n\nUsed the documented pattern."
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-stats-cell="diff")
      assert html =~ "followed"
    end

    test "Pitfalls cell renders 'none violated' when the section says so",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: "### Pitfalls\n\nNone violated. All checks honoured."
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-stats-cell="hooks")
      assert html =~ "none violated"
    end

    test "Pitfalls cell renders 'violated' when violations are called out",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: "### Pitfalls\n\nTwo pitfalls violated — see findings."
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "violated"
      refute html =~ "none violated"
    end
  end

  describe "review report panel" do
    setup [:register_and_log_in_user]

    test "renders the report markdown as styled HTML when present",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: "## Review Summary\n\nApproved with 0 findings."
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-report"
      assert html =~ "Review Summary"
      assert html =~ "Approved with 0 findings."
    end

    test "thin reviewer_result with only a summary renders no panel (D59)",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: nil,
          reviewer_result: %{
            "dispatched" => true,
            "summary" => "Reviewer prose summary when no structured report exists.",
            "acceptance_criteria_checked" => 0,
            "issues_found" => 0
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      # A thin reviewer_result (no status/issues/acceptance/section) is no
      # longer "structured"; with no review_report the panel renders nothing.
      # The reviewer summary lives in the detail header above the strip (D59).
      refute html =~ "data-review-report-panel"
      refute html =~ "Reviewer prose summary when no structured report exists."
    end

    test "thin reviewer_result WITH a review_report renders the fallback markdown, not a suppressed report (D59)",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          review_report: "## Review\n\nTwo issues found and described here.",
          reviewer_result: %{
            "dispatched" => true,
            "summary" => "Two issues noted.",
            "acceptance_criteria_checked" => 0,
            "issues_found" => 2
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-report-panel="fallback")
      assert html =~ "Two issues found and described here."
      refute html =~ "No issues"
    end

    test "renders no review report panel when neither report nor reviewer_result exists",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{review_report: nil, reviewer_result: nil})

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-report-panel"
    end
  end

  describe "completion summary panel" do
    setup [:register_and_log_in_user]

    test "renders the completion_summary section when present",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          completion_summary: "Implemented the change end to end and ran the test suite locally."
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "data-review-completion-summary"
      assert html =~ "Completion summary"
      assert html =~ "Implemented the change end to end"
    end

    test "omits the completion summary panel when nil or blank",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{completion_summary: nil})

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-completion-summary"
    end
  end

  describe "Acceptance criteria status — per-row Met / Not Met parsing" do
    setup [:register_and_log_in_user]

    test "parsed 'Met' rows render with checked styling in the checklist",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      report = """
      ### Acceptance criteria status

      1. First criterion — Met.
      2. Second criterion — Met.
      """

      _task =
        pending_task!(column, %{
          acceptance_criteria: "First criterion\nSecond criterion",
          review_report: report
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      # Scope to the acceptance checklist — `hero-x-mark` may appear elsewhere
      # in the page chrome (mobile close icons, etc.); we care that NO rows
      # inside the checklist render the failed-state X mark.
      checklist =
        Regex.run(~r/<section[^>]*data-acceptance-checklist[^>]*>.*?<\/section>/s, html)
        |> List.first()

      assert checklist
      assert length(Regex.scan(~r/hero-check/, checklist)) >= 2
      refute checklist =~ "hero-x-mark"
    end

    test "parsed 'Not Met' rows render with the red X mark",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      report = """
      ### Acceptance criteria status

      1. Passing item — Met.
      2. Failing item — Not Met.
      """

      _task =
        pending_task!(column, %{
          acceptance_criteria: "Passing item\nFailing item",
          review_report: report
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "hero-x-mark"
    end
  end

  describe "review_status_pill — direct from reviewer_result.status" do
    setup [:register_and_log_in_user]

    test "schema-1.0 status='approved' renders the green Approved pill",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{reviewer_result: %{"status" => "approved"}})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-detail-summary-status="approved")
      assert html =~ "Approved"
      assert html =~ "hero-check-circle"
    end

    test "schema-1.0 status='changes_requested' renders the red pill",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{reviewer_result: %{"status" => "changes_requested"}})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-detail-summary-status="changes_requested")
      assert html =~ "Changes requested"
      assert html =~ "hero-arrow-uturn-left"
    end

    test "unknown status string renders no pill at all",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{reviewer_result: %{"status" => "in_review"}})

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-detail-summary-status"
    end
  end

  describe "review_status_pill — neutralized when no structured status (D56)" do
    setup [:register_and_log_in_user]

    test "structured acceptance_criteria 'not_met' without a status renders the neutral pill, never changes_requested",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{
            "dispatched" => true,
            "issues_found" => 0,
            "acceptance_criteria" => [
              %{"criterion" => "A", "status" => "met"},
              %{"criterion" => "B", "status" => "not_met"}
            ]
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ ~s(data-review-detail-summary-status="changes_requested")
      assert html =~ ~s(data-review-detail-summary-status="unavailable")
      assert html =~ "Review data unavailable"
    end

    test "legacy issues_found > 0 renders the neutral pill, never changes_requested",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{"dispatched" => true, "issues_found" => 2}
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ ~s(data-review-detail-summary-status="changes_requested")
      assert html =~ ~s(data-review-detail-summary-status="unavailable")
      assert html =~ "Review data unavailable"
    end

    test "dispatched=true with no structured status renders the neutral pill, never approved",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{"dispatched" => true, "issues_found" => 0}
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ ~s(data-review-detail-summary-status="approved")
      assert html =~ ~s(data-review-detail-summary-status="unavailable")
      assert html =~ "Review data unavailable"
    end

    test "skipped reviewer (dispatched=false) renders no pill",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{"dispatched" => false, "reason" => "small_task_0_1_key_files"}
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-detail-summary-status"
    end

    test "no reviewer_result at all renders no pill",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{reviewer_result: nil})

      {:ok, _view, html} = live(conn, ~p"/review")
      refute html =~ "data-review-detail-summary-status"
    end

    test "genuine status='changes_requested' with populated issues[] still renders changes_requested",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{
            "status" => "changes_requested",
            "issues" => [
              %{
                "severity" => "critical",
                "category" => "pitfall",
                "description" => "Direct Ecto in LiveView"
              }
            ]
          }
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-detail-summary-status="changes_requested")
      assert html =~ "Changes requested"
    end

    test "status='approved' with empty issues[] renders approved and does not contradict",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          reviewer_result: %{"status" => "approved", "issues" => []}
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-detail-summary-status="approved")
      refute html =~ ~s(data-review-detail-summary-status="changes_requested")
    end
  end

  describe "task_files — diff-panel file list sourcing" do
    setup [:register_and_log_in_user]

    test "lists paths from changed_files when actual_files_changed is empty",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          actual_files_changed: "",
          changed_files: [
            %{"path" => "lib/new_only.ex", "diff" => "+ added"},
            %{"path" => "lib/another.ex", "diff" => nil}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-diff-panel-file-path="lib/new_only.ex")
      assert html =~ ~s(data-review-diff-panel-file-path="lib/another.ex")
    end

    test "lists paths from actual_files_changed when changed_files is empty (legacy)",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          actual_files_changed: "lib/legacy_one.ex, lib/legacy_two.ex",
          changed_files: []
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-diff-panel-file-path="lib/legacy_one.ex")
      assert html =~ ~s(data-review-diff-panel-file-path="lib/legacy_two.ex")
    end

    test "deduplicates paths that appear in both fields",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          actual_files_changed: "lib/shared.ex, lib/legacy_only.ex",
          changed_files: [%{"path" => "lib/shared.ex", "diff" => "+ x"}]
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      # Each path should appear in the panel exactly once.
      shared_occurrences =
        html
        |> String.split(~s(data-review-diff-panel-file-path="lib/shared.ex"))
        |> length()
        |> Kernel.-(1)

      assert shared_occurrences == 1
      assert html =~ ~s(data-review-diff-panel-file-path="lib/legacy_only.ex")
    end

    test "silently skips changed_files entries that have no path",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)

      _task =
        pending_task!(column, %{
          actual_files_changed: "",
          changed_files: [
            %{"path" => "lib/has_path.ex"},
            %{"diff" => "+ orphan"},
            %{"path" => ""}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~s(data-review-diff-panel-file-path="lib/has_path.ex")
      # The malformed entries don't blow up the render — only the valid one
      # appears as a clickable file row.
      assert html =~ "data-review-diff-panel"
      refute html =~ ~s(data-review-diff-panel-file-path="")
    end

    test "neither field populated renders the panel's empty-state",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{actual_files_changed: "", changed_files: []})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "No files changed."
    end
  end

  describe "summary_text fallback chain" do
    setup [:register_and_log_in_user]

    test "renders task.what when present", %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{what: "Specific what text", description: "ignored"})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "Specific what text"
    end

    test "falls back to task.description when :what is nil",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{what: nil, description: "Description-only text"})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "Description-only text"
    end

    test "treats empty-string :what as missing and uses description",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      _task = pending_task!(column, %{what: "", description: "Fallback fires"})

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "Fallback fires"
    end
  end

  describe "queue_subtitle pluralization + age suffix" do
    setup [:register_and_log_in_user]

    test "renders 'just now' when the oldest task is < 1 minute old",
         %{conn: conn, user: user} do
      %{column: column} = setup_review_column(user)
      task = pending_task!(column, %{completed_by_agent: "Claude"})
      _ = backdate_updated_at!(task, -2)

      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ ~r/just now/
    end

    test "no age suffix when there are no pending tasks",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review")
      assert html =~ "0 tasks waiting on you."
      refute html =~ "oldest"
    end
  end
end
