defmodule KanbanWeb.TaskLive.AttachmentsComponentTest do
  # Not async: tests change the Limits env and switch plan enforcement on.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments
  alias Kanban.Attachments.Limits
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks.Comments
  alias KanbanWeb.TaskLive.AttachmentsComponent
  alias KanbanWeb.TaskLive.AttachmentUploads

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:kanban, Limits)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, Limits, previous),
        else: Application.delete_env(:kanban, Limits)
    end)

    :ok
  end

  defp open_task_view(conn, board, task) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "view_task", %{"id" => to_string(task.id)})
    :timer.sleep(200)
    view
  end

  defp section(task), do: "#" <> AttachmentsComponent.dom_id(:view, task.id)
  defp upload_form(task), do: section(task) <> "-upload-form"

  defp board_with_task(user) do
    board = board_fixture(user)
    task = board |> column_fixture() |> task_fixture()
    {board, task}
  end

  defp upload(view, task, files) do
    input = file_input(view, upload_form(task), :files, files)

    for %{name: name} <- files do
      render_upload(input, name)
    end

    input
  end

  defp submit_upload(view, task), do: view |> element(upload_form(task)) |> render_submit()

  defp listed(task, user) do
    {:ok, attachments} =
      user
      |> Scope.for_user()
      |> Attachments.list_task_attachments(%Kanban.Tasks.Task{id: task.id})

    attachments
  end

  defp put_limits(limits), do: Application.put_env(:kanban, Limits, limits)

  # Whether the view host's component still has a usable :files upload,
  # read from the LiveView's component state. A disallowed upload keeps its
  # key with allowed?: false.
  defp files_upload_registered?(view, task) do
    %{components: {components, _ids, _uuids}} = :sys.get_state(view.pid)
    dom_id = AttachmentsComponent.dom_id(:view, task.id)

    Enum.any?(components, fn
      {_cid, {AttachmentsComponent, ^dom_id, assigns, _private, _prints}} ->
        match?(%{allowed?: true}, (assigns[:uploads] || %{})[:files])

      _other ->
        false
    end)
  end

  describe "dom_id/2 and refresh/1" do
    test "dom_id/2 keeps each host's id distinct" do
      assert AttachmentsComponent.dom_id(:view, 7) == "attachments-view-7"
      assert AttachmentsComponent.dom_id(:form, 7) == "attachments-form-7"
    end

    test "refresh/1 accepts the broadcast payload and ignores anything else" do
      assert AttachmentsComponent.refresh(%{task_id: 123, board_id: 1}) == :ok
      assert AttachmentsComponent.refresh(:unexpected) == :ok
    end
  end

  describe "in the board's task view modal" do
    test "a modify member uploads a file and sees it listed with a download link",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      modifier = user_fixture()
      {:ok, modifier} = Kanban.Accounts.update_user_name(modifier, %{name: "Ada Lovelace"})
      {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
      view = conn |> log_in_user(modifier) |> open_task_view(board, task)

      assert has_element?(view, upload_form(task))
      assert render(view) =~ "Drop files here or browse"

      upload(view, task, [%{name: "notes.txt", content: "hello", type: "text/plain"}])
      assert has_element?(view, upload_form(task) <> " progress")
      submit_upload(view, task)

      assert [attachment] = listed(task, owner)
      assert attachment.filename == "notes.txt"
      assert attachment.uploaded_by_id == modifier.id

      row = view |> element("#{section(task)}-attachment-#{attachment.id}") |> render()
      assert row =~ "notes.txt"
      assert row =~ "5 B"
      assert row =~ "Ada Lovelace"
      assert row =~ ~s(href="/attachments/#{attachment.id}/download")
      assert render(view) =~ "Uploaded 1 file"
    end

    test "uploads several files at once", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      upload(view, task, [
        %{name: "a.txt", content: "one", type: "text/plain"},
        %{name: "b.csv", content: "x,y", type: "text/csv"}
      ])

      submit_upload(view, task)

      assert task |> listed(owner) |> Enum.map(& &1.filename) |> Enum.sort() == ["a.txt", "b.csv"]
      assert render(view) =~ "Uploaded 2 files"
    end

    test "a file over the size limit shows the translated too-large error",
         %{conn: conn, user: owner} do
      put_limits(max_file_bytes: 16)
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      input =
        file_input(view, upload_form(task), :files, [
          %{name: "big.txt", content: String.duplicate("a", 17), type: "text/plain"}
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.txt")
      assert render(view) =~ AttachmentUploads.error_message(:too_large)

      submit_upload(view, task)
      assert listed(task, owner) == []
    end

    test "a file exactly at the size limit is stored", %{conn: conn, user: owner} do
      put_limits(max_file_bytes: 16)
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      upload(view, task, [
        %{name: "fits.txt", content: String.duplicate("a", 16), type: "text/plain"}
      ])

      submit_upload(view, task)
      assert [%{byte_size: 16}] = listed(task, owner)
    end

    test "a file type outside the accept list shows the translated not-accepted error",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      input =
        file_input(view, upload_form(task), :files, [
          %{name: "tool.exe", content: "MZ", type: "application/x-msdownload"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "tool.exe")
      assert render(view) =~ AttachmentUploads.error_message(:not_accepted)

      submit_upload(view, task)
      assert listed(task, owner) == []
    end

    test "an upper-case extension is accepted", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      upload(view, task, [%{name: "README.TXT", content: "hi there", type: "text/plain"}])
      submit_upload(view, task)

      assert [%{filename: "README.TXT"}] = listed(task, owner)
    end

    test "selecting more files than the limit shows the too-many-files error",
         %{conn: conn, user: owner} do
      put_limits(max_files_per_task: 1)
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      file_input(view, upload_form(task), :files, [
        %{name: "a.txt", content: "one", type: "text/plain"},
        %{name: "b.txt", content: "two", type: "text/plain"}
      ])
      |> render_upload("a.txt")

      assert render(view) =~ AttachmentUploads.error_message(:too_many_files)
    end

    test "shows the context refusal when the task already has the maximum number of attachments",
         %{conn: conn, user: owner} do
      put_limits(max_files_per_task: 2)
      {board, task} = board_with_task(owner)
      attachment_fixture(task, %{uploaded_by: owner})
      attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)

      upload(view, task, [%{name: "third.txt", content: "three", type: "text/plain"}])
      submit_upload(view, task)

      html = render(view)
      assert html =~ "Could not upload third.txt"
      assert html =~ AttachmentUploads.error_message(:too_many_files)
      assert length(listed(task, owner)) == 2
    end

    test "names a refused file the way it would be stored, in the row and the flash",
         %{conn: conn, user: owner} do
      put_limits(max_files_per_task: 1)
      {board, task} = board_with_task(owner)
      attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)

      upload(view, task, [%{name: "invoice\u202Egpj.txt", content: "x", type: "text/plain"}])
      assert render(view) =~ "invoicegpj.txt"
      refute render(view) =~ "\u202E"

      submit_upload(view, task)

      html = render(view)
      assert html =~ "Could not upload invoicegpj.txt:"
      refute html =~ "\u202E"
    end

    test "shows the empty state when a task has no attachments", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      assert has_element?(view, section(task) <> "-empty", "No attachments yet")
      assert view |> element(section(task)) |> render() =~ "0"
    end

    test "shows Unknown for an attachment whose uploader was deleted",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      gone = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, gone, :modify, owner)
      attachment = attachment_fixture(task, %{uploaded_by: gone, filename: "orphan.txt"})
      Repo.delete!(gone)

      view = open_task_view(conn, board, task)

      row = view |> element("#{section(task)}-attachment-#{attachment.id}") |> render()
      assert row =~ "orphan.txt"
      assert row =~ "Unknown"
    end

    test "lists two attachments with the same name and escapes a crafted name",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      first = attachment_fixture(task, %{filename: "same.txt"})
      second = attachment_fixture(task, %{filename: "same.txt"})
      attachment_fixture(task, %{filename: "<b>résumé</b>.txt"})

      view = open_task_view(conn, board, task)
      html = view |> element(section(task)) |> render()

      assert has_element?(view, "#{section(task)}-attachment-#{first.id}")
      assert has_element?(view, "#{section(task)}-attachment-#{second.id}")
      assert html =~ "&lt;b&gt;résumé&lt;/b&gt;.txt"
      refute html =~ "<b>résumé</b>"
    end

    test "deleting an attachment asks for confirmation and removes it from the list",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)
      button = "#{section(task)}-attachment-#{attachment.id} button[phx-click='delete']"

      assert has_element?(view, button <> "[data-confirm]")
      view |> element(button) |> render_click()

      refute has_element?(view, "#{section(task)}-attachment-#{attachment.id}")
      assert render(view) =~ "Attachment deleted"
      assert listed(task, owner) == []
    end

    test "deleting an attachment removed in another session reloads the list",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)

      # Deleted behind the view's back, without a broadcast.
      Repo.delete!(attachment)

      view
      |> element("#{section(task)}-attachment-#{attachment.id} button[phx-click='delete']")
      |> render_click()

      assert render(view) =~ "This attachment no longer exists."
      refute has_element?(view, "#{section(task)}-attachment-#{attachment.id}")
    end

    test "an attachment deleted in another session disappears through the broadcast",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)
      assert has_element?(view, "#{section(task)}-attachment-#{attachment.id}")

      {:ok, _} = owner |> Scope.for_user() |> Attachments.delete_attachment(attachment)
      _ = render(view)

      refute has_element?(view, "#{section(task)}-attachment-#{attachment.id}")
    end

    test "a modify member cannot delete another member's attachment", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      modifier = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, modifier, :modify, owner)
      others = attachment_fixture(task, %{uploaded_by: owner})
      mine = attachment_fixture(task, %{uploaded_by: modifier})
      view = conn |> log_in_user(modifier) |> open_task_view(board, task)

      refute has_element?(view, "#{section(task)}-attachment-#{others.id} button")
      assert has_element?(view, "#{section(task)}-attachment-#{mine.id} button")

      view
      |> with_target(section(task))
      |> render_click("delete", %{"id" => to_string(others.id)})

      assert render(view) =~ AttachmentUploads.error_message(:unauthorized)
      assert length(listed(task, owner)) == 2
    end

    test "a read_only member sees attachments but no upload or delete control",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner, filename: "spec.pdf"})
      view = conn |> log_in_user(reader) |> open_task_view(board, task)

      html = view |> element(section(task)) |> render()
      assert html =~ "spec.pdf"
      assert html =~ ~s(href="/attachments/#{attachment.id}/download")
      refute has_element?(view, upload_form(task))
      refute html =~ "Drop files here or browse"
      refute html =~ "Upload files"
      refute has_element?(view, "#{section(task)}-attachment-#{attachment.id} button")
    end

    test "refuses a forged upload or delete event from a read_only member",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner})
      view = conn |> log_in_user(reader) |> open_task_view(board, task)

      view |> with_target(section(task)) |> render_click("upload", %{})
      assert render(view) =~ AttachmentUploads.error_message(:unauthorized)

      view
      |> with_target(section(task))
      |> render_click("delete", %{"id" => to_string(attachment.id)})

      assert render(view) =~ AttachmentUploads.error_message(:unauthorized)
      assert [%{id: id}] = listed(task, owner)
      assert id == attachment.id

      # A forged cancel for an upload that was never allowed is a no-op.
      view |> with_target(section(task)) |> render_click("cancel-upload", %{"ref" => "0"})
      assert has_element?(view, section(task))
    end

    test "an upload refused after a silent downgrade drops the upload registration",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      view = conn |> log_in_user(member) |> open_task_view(board, task)

      upload(view, task, [%{name: "late.txt", content: "late", type: "text/plain"}])
      assert files_upload_registered?(view, task)

      # A downgrade whose broadcast has not reached this view yet: the
      # component still holds its load-time rights when the submit arrives.
      from(bu in Kanban.Boards.BoardUser,
        where: bu.board_id == ^board.id and bu.user_id == ^member.id
      )
      |> Repo.update_all(set: [access: :read_only])

      submit_upload(view, task)

      assert render(view) =~ AttachmentUploads.error_message(:unauthorized)
      assert listed(task, owner) == []
      refute has_element?(view, upload_form(task))
      refute files_upload_registered?(view, task)
    end

    test "a member downgraded and then restored mid-session can upload again",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      view = conn |> log_in_user(member) |> open_task_view(board, task)

      {:ok, _} = Boards.update_user_access(board, member, :read_only, owner)
      :timer.sleep(100)
      refute has_element?(view, upload_form(task))

      {:ok, _} = Boards.update_user_access(board, member, :modify, owner)
      :timer.sleep(100)
      assert has_element?(view, upload_form(task))

      upload(view, task, [%{name: "back.txt", content: "back", type: "text/plain"}])
      submit_upload(view, task)

      assert [%{filename: "back.txt"}] = listed(task, owner)
    end

    test "cancelling a staged entry removes it", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      input =
        file_input(view, upload_form(task), :files, [
          %{name: "draft.txt", content: "wip", type: "text/plain"}
        ])

      render_upload(input, "draft.txt", 50)
      assert render(view) =~ "draft.txt"

      [entry] = upload_entry_refs(view, task)

      view
      |> element("#{upload_form(task)} button[phx-value-ref='#{entry}']")
      |> render_click()

      refute view |> element(upload_form(task)) |> render() =~ "draft.txt"
      submit_upload(view, task)
      assert listed(task, owner) == []
    end

    test "a partly successful submit names the stored files and the refused one",
         %{conn: conn, user: owner} do
      put_limits(max_files_per_task: 2)
      {board, task} = board_with_task(owner)
      attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)

      upload(view, task, [
        %{name: "fits.txt", content: "one", type: "text/plain"},
        %{name: "extra.txt", content: "two", type: "text/plain"}
      ])

      submit_upload(view, task)

      html = render(view)
      # Two sentences: the count ends with a full stop before the refusal.
      assert html =~ ~r/Uploaded 1 file\. Could not upload (fits|extra)\.txt:/
      assert length(listed(task, owner)) == 2
    end

    test "the Upload files button waits for a finished, valid entry", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)
      button = upload_form(task) <> " button[type='submit']"

      assert has_element?(view, button <> "[disabled]")

      input =
        file_input(view, upload_form(task), :files, [
          %{name: "slow.txt", content: "partial", type: "text/plain"}
        ])

      render_upload(input, "slow.txt", 50)
      assert has_element?(view, button <> "[disabled]")

      done_view = open_task_view(conn, board, task)
      upload(done_view, task, [%{name: "done.txt", content: "done", type: "text/plain"}])
      refute has_element?(done_view, button <> "[disabled]")
    end

    test "a task deleted while its modal is open refuses upload and delete without crashing",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner})
      view = open_task_view(conn, board, task)
      upload(view, task, [%{name: "late.txt", content: "late", type: "text/plain"}])

      # Deleted behind the open modal, without a broadcast.
      Repo.delete!(task)

      submit_upload(view, task)
      html = render(view)
      assert html =~ "Could not upload late.txt"
      assert html =~ AttachmentUploads.error_message(:not_found)

      view
      |> with_target(section(task))
      |> render_click("delete", %{"id" => to_string(attachment.id)})

      assert render(view) =~ "This attachment no longer exists."
      refute has_element?(view, "#{section(task)}-attachment-#{attachment.id}")
      assert has_element?(view, section(task) <> "-empty")
    end

    test "submitting with nothing staged asks to choose files", %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      view |> with_target(section(task)) |> render_click("upload", %{})
      assert render(view) =~ "Choose files to upload first."
    end

    test "a free board shows the LockedFeature panel and no upload control",
         %{conn: conn, user: owner} do
      enforce_plans()
      {board, task} = board_with_task(owner)
      attachment = attachment_fixture(task, %{uploaded_by: owner, filename: "hidden.txt"})
      view = open_task_view(conn, board, task)

      assert has_element?(view, section(task) <> "-lock")
      refute has_element?(view, upload_form(task))
      refute view |> element(section(task)) |> render() =~ "hidden.txt"

      view |> with_target(section(task)) |> render_click("upload", %{})
      assert render(view) =~ AttachmentUploads.error_message({:plan_required, :attachments})

      view
      |> with_target(section(task))
      |> render_click("delete", %{"id" => to_string(attachment.id)})

      assert Repo.get(Kanban.Attachments.TaskAttachment, attachment.id)
    end

    test "the task view modal mounts the Attachments section and routes its flash",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)

      assert has_element?(view, section(task))
      html = render(view)
      {attachments_at, _} = :binary.match(html, ~s(id="attachments-view-#{task.id}"))
      {history_at, _} = :binary.match(html, "History")
      assert attachments_at < history_at

      view |> with_target(section(task)) |> render_click("delete", %{"id" => "0"})
      assert render(view) =~ "This attachment no longer exists."
    end

    test "lists only task-level attachments, not comment attachments",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)

      {:ok, comment} =
        owner |> Scope.for_user() |> Comments.create_comment(task, %{"content" => "see file"})

      attachment_fixture(task, %{comment: comment, filename: "on-comment.txt"})
      on_task = attachment_fixture(task, %{filename: "on-task.txt"})
      view = open_task_view(conn, board, task)

      html = view |> element(section(task)) |> render()
      assert html =~ "on-task.txt"
      refute html =~ "on-comment.txt"
      assert has_element?(view, "#{section(task)}-attachment-#{on_task.id}")
    end

    test "the task view shows a thumbnail whose src is the preview route",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      image = attachment_fixture(task, %{filename: "shot.png", content_type: "image/png"})
      pdf = attachment_fixture(task, %{filename: "spec.pdf", content_type: "application/pdf"})
      view = open_task_view(conn, board, task)

      lightbox = "#{section(task)}-attachment-#{image.id}-lightbox"

      assert has_element?(
               view,
               ~s(#{lightbox}-open img[src="/attachments/#{image.id}/preview"][loading="lazy"])
             )

      assert has_element?(view, ~s(#{lightbox}[role="dialog"]))
      assert has_element?(view, ~s(#{lightbox} a[href="/attachments/#{image.id}/download"]))

      refute view
             |> element("#{section(task)}-attachment-#{pdf.id}")
             |> render() =~ "/preview"
    end
  end

  defp upload_entry_refs(view, task) do
    html = view |> element(upload_form(task)) |> render()

    ~r/phx-value-ref="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
