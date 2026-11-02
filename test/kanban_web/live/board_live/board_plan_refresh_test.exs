defmodule KanbanWeb.BoardLive.BoardPlanRefreshTest do
  # Not async: tests switch the global :plans_enforced env on.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 3]
  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.BoardMoves
  alias KanbanWeb.TaskLive.AttachmentsComponent
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.CommentThreadComponent
  alias KanbanWeb.TaskLive.Form.AttachmentStaging

  # A board moved into or out of an Organization changes its plan, and
  # BoardMoves tells open views with {Kanban.Boards, :members_changed, id}.
  # Every open surface with a plan-gated control must follow it without a
  # reload.

  setup :register_and_log_in_user
  setup :enforce_plans

  setup %{user: owner} do
    organization = organization_fixture()
    organization_member_fixture(organization, owner, :org_admin)
    workspace = org_workspace_fixture(organization)
    board = board_fixture(owner)

    # Show the Observability section, which holds the paid telemetry fields.
    {1, _} =
      Board
      |> where([b], b.id == ^board.id)
      |> Repo.update_all(set: [field_visibility: %{"observability" => true}])

    board = Repo.get!(Board, board.id)
    column = column_fixture(board)
    task = task_fixture(column)

    %{board: board, column: column, task: task, workspace: workspace}
  end

  defp open_task_view(conn, board, task) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "view_task", %{"id" => to_string(task.id)})
    :timer.sleep(200)
    view
  end

  defp section(host, task), do: "#" <> AttachmentsComponent.dom_id(host, task.id)
  defp upload_form(host, task), do: section(host, task) <> "-upload-form"

  defp composer_input(task),
    do: "#" <> CommentThreadComponent.dom_id(:view, task.id) <> ~s(-composer input[type="file"])

  defp move_into_organization(owner, board, workspace) do
    {:ok, _board} = BoardMoves.move_board_to_workspace(owner, board, workspace)
    :timer.sleep(100)
  end

  # BoardMoves only moves a board into an Organization; leaving one is done
  # by an operator, which broadcasts the same message.
  defp move_out_of_organization(owner, board) do
    personal = Workspaces.get_personal_workspace(owner)

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: personal.id])

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board.id}",
      {Kanban.Boards, :members_changed, board.id}
    )

    :timer.sleep(100)
  end

  defp stage(view, host, task, name) do
    view
    |> file_input(upload_form(host, task), :files, [
      %{name: name, content: "staged", type: "text/plain"}
    ])
    |> render_upload(name)
  end

  describe "the task view" do
    test "offers uploads and comment files once the board joins an Organization",
         %{conn: conn, user: owner, board: board, task: task, workspace: workspace} do
      view = open_task_view(conn, board, task)
      assert has_element?(view, section(:view, task) <> "-lock")
      refute has_element?(view, composer_input(task))

      move_into_organization(owner, board, workspace)

      refute has_element?(view, section(:view, task) <> "-lock")
      assert has_element?(view, upload_form(:view, task))
      assert has_element?(view, composer_input(task))

      stage(view, :view, task, "joined.txt")
      view |> element(upload_form(:view, task)) |> render_submit()

      assert render(view) =~ "Uploaded 1 file."
      assert Repo.aggregate(TaskAttachment, :count) == 1
    end

    test "locks, and names and drops the staged files, once the board leaves its Organization",
         %{conn: conn, user: owner, board: board, task: task, workspace: workspace} do
      move_into_organization(owner, board, workspace)
      view = open_task_view(conn, board, task)
      stage(view, :view, task, "left.txt")

      move_out_of_organization(owner, board)

      assert has_element?(view, section(:view, task) <> "-lock")
      refute has_element?(view, upload_form(:view, task))
      refute has_element?(view, composer_input(task))

      assert render(view) =~
               "Could not upload left.txt: " <>
                 AttachmentUploads.error_message({:plan_required, :attachments})

      move_into_organization(owner, board, workspace)

      assert has_element?(view, upload_form(:view, task))
      refute has_element?(view, upload_form(:view, task) <> " progress")
      assert Repo.aggregate(TaskAttachment, :count) == 0
    end

    test "names and drops staged files when a submit finds the plan gone",
         %{conn: conn, board: board, task: task} do
      Application.put_env(:kanban, :plans_enforced, false)
      view = open_task_view(conn, board, task)
      stage(view, :view, task, "lapsed.txt")

      Application.put_env(:kanban, :plans_enforced, true)
      view |> element(upload_form(:view, task)) |> render_submit()

      assert render(view) =~
               "Could not upload lapsed.txt: " <>
                 AttachmentUploads.error_message({:plan_required, :attachments})

      Application.put_env(:kanban, :plans_enforced, false)

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{board.id}",
        {Kanban.Attachments, :attachment_changed, %{task_id: task.id}}
      )

      :timer.sleep(100)

      assert has_element?(view, upload_form(:view, task))
      refute has_element?(view, upload_form(:view, task) <> " progress")
      assert Repo.aggregate(TaskAttachment, :count) == 0
    end
  end

  describe "the task forms" do
    test "the new-task form offers its Attachments field once the board joins an Organization",
         %{conn: conn, user: owner, board: board, column: column, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")
      assert has_element?(view, ~s(#task-attachments[data-attachment-staging="locked"]))
      assert has_element?(view, "#task-telemetry-lock")

      move_into_organization(owner, board, workspace)

      assert has_element?(view, ~s(#task-attachments[data-attachment-staging="open"]))
      refute has_element?(view, "#task-telemetry-lock")

      view
      |> file_input("#task-form", AttachmentStaging.upload_name(), [
        %{name: "new.txt", content: "new", type: "text/plain"}
      ])
      |> render_upload("new.txt")

      view
      |> element("#task-form")
      |> render_submit(%{"task" => %{"title" => "After the move", "column_id" => column.id}})

      assert [%{filename: "new.txt"}] = Repo.all(TaskAttachment)
    end

    test "the new-task form locks its Attachments field once the board leaves its Organization",
         %{conn: conn, user: owner, board: board, column: column, workspace: workspace} do
      move_into_organization(owner, board, workspace)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/columns/#{column}/tasks/new")
      assert has_element?(view, ~s(#task-attachments[data-attachment-staging="open"]))

      move_out_of_organization(owner, board)

      assert has_element?(view, ~s(#task-attachments[data-attachment-staging="locked"]))
      assert has_element?(view, "#task-telemetry-lock")
    end

    test "the edit form's Attachments section follows the board's plan",
         %{conn: conn, user: owner, board: board, task: task, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
      assert has_element?(view, section(:form, task) <> "-lock")

      move_into_organization(owner, board, workspace)

      refute has_element?(view, section(:form, task) <> "-lock")
      assert has_element?(view, upload_form(:form, task))
    end
  end
end
