defmodule KanbanWeb.ArchiveLive.AttachmentsTest do
  # Not async: one test switches the global :plans_enforced env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Phoenix.LiveViewTest

  alias Kanban.Boards
  alias Kanban.Tasks

  setup %{conn: conn} do
    owner = user_fixture()
    board = board_fixture(owner)
    column = column_fixture(board)
    {:ok, task} = column |> task_fixture(%{title: "Archived with files"}) |> Tasks.archive_task()
    %{conn: conn, owner: owner, board: board, column: column, task: task}
  end

  defp files(view, task), do: element(view, "#archive-files-#{task.id}")

  test "an archived task's files are listed with Download and no Delete", ctx do
    attachment = attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "log.txt"})

    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    html = view |> files(ctx.task) |> render()
    assert html =~ "1 file"
    assert html =~ "log.txt"
    assert html =~ ~p"/attachments/#{attachment.id}/download"
    refute html =~ "Delete log.txt"
    refute has_element?(view, ~s{#archive-files-#{ctx.task.id} [phx-click="delete-attachment"]})
  end

  test "counts every file on the task, a comment's included", ctx do
    {:ok, comment} =
      ctx.owner
      |> Kanban.Accounts.Scope.for_user()
      |> Kanban.Tasks.Comments.create_comment(ctx.task, %{"content" => "see file"})

    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner})
    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, comment: comment})

    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    assert view |> files(ctx.task) |> render() =~ "2 files"
  end

  test "a read-only member sees the files too", ctx do
    reader = user_fixture()
    {:ok, _} = Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.owner)
    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "notes.md"})
    {:ok, view, _html} = ctx.conn |> log_in_user(reader) |> live(~p"/boards/#{ctx.board}/archive")

    assert view |> files(ctx.task) |> render() =~ "notes.md"
  end

  test "a task without files shows no file list", ctx do
    {:ok, view, html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    assert html =~ "Archived with files"
    refute has_element?(view, "#archive-files-#{ctx.task.id}")
  end

  test "a non-member viewing a public board sees no files", ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{read_only: true}, ctx.owner)
    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "hidden.txt"})

    {:ok, view, html} =
      ctx.conn |> log_in_user(user_fixture()) |> live(~p"/boards/#{board}/archive")

    assert html =~ "Archived with files"
    refute has_element?(view, "#archive-files-#{ctx.task.id}")
    refute html =~ "hidden.txt"
  end

  test "a free board lists no files while plans are enforced, and records no refusal", ctx do
    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "locked.txt"})
    enforce_plans()
    attach_telemetry([[:kanban, :plan, :feature_refused]])

    {:ok, view, html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    refute has_element?(view, "#archive-files-#{ctx.task.id}")
    refute html =~ "locked.txt"

    refute_received {:telemetry_event, [:kanban, :plan, :feature_refused], _,
                     %{feature: :attachments}}
  end

  test "the list refreshes when a file changes on the board", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    refute has_element?(view, "#archive-files-#{ctx.task.id}")

    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "late.txt"})

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{ctx.board.id}",
      {Kanban.Attachments, :attachment_changed, %{task_id: ctx.task.id, board_id: ctx.board.id}}
    )

    assert view |> files(ctx.task) |> render() =~ "late.txt"
  end

  test "deleting a comment drops its files from an open archive page", ctx do
    scope = Kanban.Accounts.Scope.for_user(ctx.owner)
    {:ok, comment} = Kanban.Tasks.Comments.create_comment(scope, ctx.task, %{"content" => "x"})
    attachment_fixture(ctx.task, %{uploaded_by: ctx.owner, filename: "on-task.txt"})

    attachment_fixture(ctx.task, %{
      uploaded_by: ctx.owner,
      comment: comment,
      filename: "on-comment.txt"
    })

    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.owner) |> live(~p"/boards/#{ctx.board}/archive")

    assert view |> files(ctx.task) |> render() =~ "2 files"

    assert {:ok, _} = Kanban.Tasks.Comments.delete_comment(scope, comment)

    html = view |> files(ctx.task) |> render()
    assert html =~ "1 file"
    assert html =~ "on-task.txt"
    refute html =~ "on-comment.txt"
  end
end
