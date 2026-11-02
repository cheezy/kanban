defmodule KanbanWeb.TaskLive.CommentThreadComponentTest do
  # Not async: the attachment tests change the Limits env and switch plan
  # enforcement on.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.TaskLive.AttachmentUploads
  alias KanbanWeb.TaskLive.CommentThreadComponent

  setup do
    previous = Application.get_env(:kanban, Limits)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, Limits, previous),
        else: Application.delete_env(:kanban, Limits)
    end)

    :ok
  end

  describe "update/2 and handle_event/3" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task = task_fixture(column)
      %{owner: owner, board: board, task: task}
    end

    defp mount_thread(task, user) do
      scope = if user, do: Scope.for_user(user)

      {:ok, socket} =
        CommentThreadComponent.update(
          %{
            id: CommentThreadComponent.dom_id(:form, task.id),
            task_id: task.id,
            current_scope: scope
          },
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
        )

      socket
    end

    test "adds a comment authored by the viewer and resets the composer",
         %{owner: owner, task: task} do
      socket = mount_thread(task, owner)

      # A rejected submit first leaves errors on the composer...
      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => ""}},
          socket
        )

      assert socket.assigns.comment_form.errors != []

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "New comment"}},
          socket
        )

      assert [%{comment: comment, can_edit: true}] = socket.assigns.entries
      assert comment.content == "New comment"
      assert comment.author_user_id == owner.id
      # ...which a successful post clears.
      assert socket.assigns.comment_form.errors == []
      refute socket.assigns.comment_form.source.changes[:content]
      # The success message goes to the hosting LiveView, never only to the
      # component's own flash, which LiveView would drop.
      assert_received {CommentThreadComponent, {:flash, :info, "Comment added successfully"}}
      refute socket.assigns.flash["info"]
    end

    test "sends no message to the host for a rejected comment", %{owner: owner, task: task} do
      socket = mount_thread(task, owner)

      {:noreply, _socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "   "}},
          socket
        )

      refute_received {CommentThreadComponent, {:flash, _kind, _message}}
    end

    test "attaches the comment to the server-held task, ignoring a client task_id",
         %{owner: owner, board: board, task: task} do
      other_task = board |> column_fixture() |> task_fixture()
      socket = mount_thread(task, owner)

      {:noreply, _socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "real task", "task_id" => other_task.id}},
          socket
        )

      assert [%TaskComment{task_id: task_id}] = Repo.all(TaskComment)
      assert task_id == task.id
    end

    test "shows a validation error for an empty comment", %{owner: owner, task: task} do
      socket = mount_thread(task, owner)

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => ""}},
          socket
        )

      assert Keyword.has_key?(socket.assigns.comment_form.errors, :content)
      assert socket.assigns.entries == []
    end

    test "refuses a non-member, who also gets no composer", %{task: task} do
      stranger = user_fixture()
      socket = mount_thread(task, stranger)

      refute socket.assigns.can_comment

      {:noreply, _socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "should not save"}},
          socket
        )

      assert_received {CommentThreadComponent,
                       {:flash, :error, "You must be a board member" <> _}}

      assert Repo.aggregate(TaskComment, :count) == 0
    end

    test "lets a read-only member comment", %{owner: owner, board: board, task: task} do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      socket = mount_thread(task, reader)

      assert socket.assigns.can_comment

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "I have thoughts"}},
          socket
        )

      assert length(socket.assigns.entries) == 1
    end

    test "renders read-only with no scope", %{owner: owner, task: task} do
      {:ok, _} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Visible"})

      socket = mount_thread(task, nil)

      refute socket.assigns.can_comment
      assert [%{can_edit: false, can_delete: false}] = socket.assigns.entries
    end

    test "re-authorizes a forged delete instead of trusting the rendered controls",
         %{owner: owner, board: board, task: task} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      {:ok, owners} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Owner's"})

      socket = mount_thread(task, member)

      assert [%{can_delete: false}] = socket.assigns.entries

      {:noreply, _socket} =
        CommentThreadComponent.handle_event(
          "delete_comment",
          %{"id" => to_string(owners.id)},
          socket
        )

      assert_received {CommentThreadComponent, {:flash, :error, "You are not allowed" <> _}}
      assert Repo.get(TaskComment, owners.id)
    end

    test "ignores an edit request for a comment the viewer cannot edit, or a junk id",
         %{owner: owner, board: board, task: task} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      {:ok, owners} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Owner's"})

      socket = mount_thread(task, member)

      for id <- [to_string(owners.id), "nope", "#{owners.id}x", 12] do
        {:noreply, socket} =
          CommentThreadComponent.handle_event("edit_comment", %{"id" => id}, socket)

        assert socket.assigns.editing_id == nil
      end
    end

    test "edits the server-held comment, never one named by the client",
         %{owner: owner, task: task} do
      {:ok, mine} = owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "v1"})

      {:ok, other} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "other"})

      socket = mount_thread(task, owner)

      {:noreply, socket} =
        CommentThreadComponent.handle_event("edit_comment", %{"id" => to_string(mine.id)}, socket)

      assert socket.assigns.editing_id == mine.id

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "save_comment",
          %{"id" => to_string(other.id), "task_comment" => %{"content" => "v2"}},
          socket
        )

      assert socket.assigns.editing_id == nil
      assert Repo.get!(TaskComment, mine.id).content == "v2"
      assert Repo.get!(TaskComment, mine.id).edited_at
      assert Repo.get!(TaskComment, other.id).content == "other"
    end

    test "flashes and closes the editor when the comment was deleted mid-edit",
         %{owner: owner, task: task} do
      {:ok, mine} = owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "v1"})
      socket = mount_thread(task, owner)

      {:noreply, socket} =
        CommentThreadComponent.handle_event("edit_comment", %{"id" => to_string(mine.id)}, socket)

      {:ok, _} = owner |> Scope.for_user() |> Tasks.delete_comment(mine)

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "save_comment",
          %{"task_comment" => %{"content" => "v2"}},
          socket
        )

      assert_received {CommentThreadComponent, {:flash, :error, "This comment no longer exists"}}
      assert socket.assigns.editing_id == nil
      assert socket.assigns.entries == []
    end

    test "a refresh keeps an open edit while the comment is still editable",
         %{owner: owner, task: task} do
      {:ok, mine} = owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "v1"})
      socket = mount_thread(task, owner)

      {:noreply, socket} =
        CommentThreadComponent.handle_event("edit_comment", %{"id" => to_string(mine.id)}, socket)

      {:ok, _} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "another"})

      {:ok, socket} = CommentThreadComponent.update(%{refresh: true}, socket)

      assert socket.assigns.editing_id == mine.id
      assert length(socket.assigns.entries) == 2

      {:ok, _} = owner |> Scope.for_user() |> Tasks.delete_comment(mine)
      {:ok, socket} = CommentThreadComponent.update(%{refresh: true}, socket)

      assert socket.assigns.editing_id == nil
    end

    defp add_named_member(board, owner, name) do
      member = user_fixture()
      {:ok, member} = Kanban.Accounts.update_user_name(member, %{name: name})
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      member
    end

    test "mention_search replies with board members matching the query",
         %{owner: owner, board: board, task: task} do
      grace = add_named_member(board, owner, "Grace Hopper")
      _alan = add_named_member(board, owner, "Alan Turing")
      socket = mount_thread(task, owner)

      assert {:reply, %{members: [%{id: id, label: "Grace Hopper"} = member]}, ^socket} =
               CommentThreadComponent.handle_event("mention_search", %{"query" => "gra"}, socket)

      assert id == grace.id
      assert Map.keys(member) |> Enum.sort() == [:id, :label]
    end

    test "mention_search returns at most eight members",
         %{owner: owner, board: board, task: task} do
      for n <- 1..10, do: add_named_member(board, owner, "Member #{n}")
      socket = mount_thread(task, owner)

      {:reply, %{members: members}, _socket} =
        CommentThreadComponent.handle_event("mention_search", %{"query" => "Member"}, socket)

      assert length(members) == 8
    end

    test "mention_search never returns members of another board",
         %{owner: owner, board: board, task: task} do
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      add_named_member(other_board, other_owner, "Grace Elsewhere")
      add_named_member(board, owner, "Grace Here")
      socket = mount_thread(task, owner)

      {:reply, %{members: members}, _socket} =
        CommentThreadComponent.handle_event("mention_search", %{"query" => "Grace"}, socket)

      assert Enum.map(members, & &1.label) == ["Grace Here"]
    end

    test "mention_search replies with an empty list to a non-member or no scope",
         %{owner: owner, board: board, task: task} do
      add_named_member(board, owner, "Grace Hopper")

      for viewer <- [user_fixture(), nil] do
        socket = mount_thread(task, viewer)

        assert {:reply, %{members: []}, _socket} =
                 CommentThreadComponent.handle_event("mention_search", %{"query" => "gr"}, socket)
      end
    end

    test "mention_search treats a missing or non-string query as empty",
         %{owner: owner, task: task} do
      socket = mount_thread(task, owner)

      for params <- [%{}, %{"query" => 7}, %{"query" => ["x"]}] do
        assert {:reply, %{members: members}, _socket} =
                 CommentThreadComponent.handle_event("mention_search", params, socket)

        assert Enum.map(members, & &1.id) == [owner.id]
      end
    end

    test "comment_dom_id/2 delegates to the row component" do
      assert CommentThreadComponent.comment_dom_id("comment-thread-view-7", %{id: 42}) ==
               "comment-thread-view-7-comment-42"
    end

    test "refresh/1 accepts the broadcast payload and ignores anything else" do
      assert CommentThreadComponent.refresh(%{task_id: 123, board_id: 1}) == :ok
      assert CommentThreadComponent.refresh(:unexpected) == :ok
    end
  end

  describe "in the board's task view modal" do
    setup [:register_and_log_in_user]

    defp open_task_view(conn, board, task) do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      render_hook(view, "view_task", %{"id" => to_string(task.id)})
      :timer.sleep(200)
      view
    end

    defp thread(task), do: "#" <> CommentThreadComponent.dom_id(:view, task.id)

    test "a member posts a comment and it appears with their name",
         %{conn: conn, user: user} do
      {:ok, user} = Kanban.Accounts.update_user_name(user, %{name: "Ada Lovelace"})
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      view = open_task_view(conn, board, task)

      assert has_element?(view, thread(task) <> "-composer")

      view
      |> element(thread(task) <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => "Ship it"}})

      html = view |> element(thread(task)) |> render()
      assert html =~ "Ship it"
      assert html =~ "Ada Lovelace"

      # The board page shows the thread's success message as a flash.
      assert render(view) =~ "Comment added successfully"
    end

    test "the composer carries the mention autocomplete hook and its listbox",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      view = open_task_view(conn, board, task)
      textarea = thread(task) <> "-composer_content"

      assert has_element?(view, textarea <> ~s([phx-hook="MentionAutocomplete"]))

      assert has_element?(
               view,
               textarea <> ~s([aria-controls="#{String.trim_leading(textarea, "#")}-mentions"])
             )

      assert has_element?(view, textarea <> ~s(-mentions[role="listbox"][phx-update="ignore"]))
      assert has_element?(view, textarea <> ~s(-mentions[data-empty-text="No matching members"]))
    end

    test "mention_search replies to the hook and the inserted token is stored as a mention",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      grace = user_fixture()
      {:ok, grace} = Kanban.Accounts.update_user_name(grace, %{name: "Grace Hopper"})
      {:ok, _} = Boards.add_user_to_board(board, grace, :modify, user)
      outsider = user_fixture()
      {:ok, _} = Kanban.Accounts.update_user_name(outsider, %{name: "Grace Outsider"})
      view = open_task_view(conn, board, task)

      view
      |> with_target(thread(task))
      |> render_hook("mention_search", %{"query" => "gra"})

      assert_reply(view, %{members: [%{id: id, label: label}]})
      assert id == grace.id

      view
      |> element(thread(task) <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => "ping @[#{label}](user:#{id}) "}})

      assert [comment] = Repo.all(TaskComment)
      assert comment.mentioned_user_ids == [grace.id]

      assert has_element?(
               view,
               thread(task) <> ~s( [data-mention-chip][data-user-id="#{grace.id}"])
             )
    end

    test "the inline edit textarea carries the mention autocomplete hook",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()

      {:ok, comment} =
        user |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Mine"})

      view = open_task_view(conn, board, task)

      view
      |> element(thread(task) <> ~s( [phx-click="edit_comment"][phx-value-id="#{comment.id}"]))
      |> render_click()

      edit = thread(task) <> "-edit-#{comment.id}_content"
      assert has_element?(view, edit <> ~s([phx-hook="MentionAutocomplete"]))
      assert has_element?(view, edit <> ~s(-mentions[role="listbox"]))
    end

    test "posting a comment asks the browser to scroll it into view",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      view = open_task_view(conn, board, task)

      view
      |> element(thread(task) <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => "Scroll to me"}})

      [comment] = Repo.all(TaskComment)

      row_id =
        :view
        |> CommentThreadComponent.dom_id(task.id)
        |> CommentThreadComponent.comment_dom_id(comment)

      assert_push_event(view, "comment-thread:scroll-to", %{id: ^row_id})
      # The id names a row that is on the page.
      assert has_element?(view, "#" <> row_id, "Scroll to me")
    end

    test "a mention of a board member renders as a chip with their name",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      member = user_fixture()
      {:ok, member} = Kanban.Accounts.update_user_name(member, %{name: "Grace Hopper"})
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, user)
      outsider = user_fixture()
      view = open_task_view(conn, board, task)

      content = "cc @[Grace](user:#{member.id}) and @[Eve](user:#{outsider.id})"

      view
      |> element(thread(task) <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => content}})

      html = view |> element(thread(task)) |> render()
      assert html =~ ~s(data-user-id="#{member.id}")
      assert html =~ "@Grace Hopper"
      refute html =~ ~s(data-user-id="#{outsider.id}")
      assert html =~ "@[Eve](user:#{outsider.id})"
    end

    test "a rejected comment asks for no scroll", %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      view = open_task_view(conn, board, task)

      view
      |> element(thread(task) <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => ""}})

      refute_push_event(view, "comment-thread:scroll-to", %{})
    end

    test "the board page shows an error message the thread sends it",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      view = open_task_view(conn, board, task)

      send(
        view.pid,
        {CommentThreadComponent, {:flash, :error, "You are not allowed to change this comment"}}
      )

      assert render(view) =~ "You are not allowed to change this comment"
    end

    test "the author edits and deletes their comment", %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()

      {:ok, comment} =
        user |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Draft"})

      view = open_task_view(conn, board, task)

      view
      |> element("#{thread(task)} button[phx-click='edit_comment'][phx-value-id='#{comment.id}']")
      |> render_click()

      view
      |> element("#{thread(task)}-edit-#{comment.id}")
      |> render_submit(%{"task_comment" => %{"content" => "Final"}})

      html = view |> element(thread(task)) |> render()
      assert html =~ "Final"
      assert html =~ "data-comment-edited"

      view
      |> element(
        "#{thread(task)} button[phx-click='delete_comment'][phx-value-id='#{comment.id}']"
      )
      |> render_click()

      refute Repo.get(TaskComment, comment.id)
      assert view |> element(thread(task)) |> render() =~ "No comments yet"
    end

    test "a non-author member sees no edit or delete controls", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      task = board |> column_fixture() |> task_fixture()

      {:ok, _} =
        owner |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Owner note"})

      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      view = conn |> log_in_user(member) |> open_task_view(board, task)

      html = view |> element(thread(task)) |> render()
      assert html =~ "Owner note"
      refute html =~ "edit_comment"
      refute html =~ "delete_comment"
      assert has_element?(view, thread(task) <> "-composer")
    end

    test "the board owner may delete but not edit someone else's comment", %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      task = board |> column_fixture() |> task_fixture()
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      {:ok, _} =
        member |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "Member note"})

      view = conn |> log_in_user(owner) |> open_task_view(board, task)

      html = view |> element(thread(task)) |> render()
      refute html =~ "edit_comment"
      assert html =~ "delete_comment"
    end

    test "a comment written in another session appears without reload",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()
      other = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, other, :read_only, user)
      view = open_task_view(conn, board, task)

      refute view |> element(thread(task)) |> render() =~ "From elsewhere"

      {:ok, _} =
        other |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "From elsewhere"})

      # The broadcast's handle_info replies with a send_update the view
      # processes after it; the first render drains the queue.
      _ = render(view)
      assert view |> element(thread(task)) |> render() =~ "From elsewhere"
    end
  end

  describe "in the task edit form" do
    setup [:register_and_log_in_user]

    test "mounts the same thread with a composer", %{conn: conn, user: user} do
      board = board_fixture(user)
      task = board |> column_fixture() |> task_fixture()

      {:ok, _} =
        user |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "In the form"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")

      form_thread = "#" <> CommentThreadComponent.dom_id(:form, task.id)
      assert view |> element(form_thread) |> render() =~ "In the form"

      view
      |> element(form_thread <> "-composer")
      |> render_submit(%{"task_comment" => %{"content" => "Added from the form"}})

      assert view |> element(form_thread) |> render() =~ "Added from the form"

      assert has_element?(
               view,
               form_thread <> ~s(-composer_content[phx-hook="MentionAutocomplete"])
             )
    end
  end

  describe "comment attachments" do
    setup [:register_and_log_in_user]

    defp composer(task), do: thread(task) <> "-composer"

    defp board_with_task(user) do
      board = board_fixture(user)
      {board, board |> column_fixture() |> task_fixture()}
    end

    defp stage(view, selector, files) do
      input = file_input(view, selector, :comment_attachments, files)
      for %{name: name} <- files, do: render_upload(input, name)
      input
    end

    defp post_comment(view, selector, content) do
      view
      |> element(selector)
      |> render_submit(%{"task_comment" => %{"content" => content}})
    end

    defp notes, do: %{name: "notes.txt", content: "hello", type: "text/plain"}

    defp row(task, comment) do
      thread_id = CommentThreadComponent.dom_id(:view, task.id)
      "#" <> CommentThreadComponent.comment_dom_id(thread_id, comment)
    end

    defp file_row(task, comment, attachment),
      do: row(task, comment) <> "-attachments-attachment-#{attachment.id}"

    defp remove_button, do: ~s(button[phx-click="remove_comment_attachment"])

    defp comment_with_file(board, owner, task) do
      author = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, author, :modify, owner)

      {:ok, comment} =
        author |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "See log"})

      attachment = attachment_fixture(task, %{comment: comment, uploaded_by: author})
      {author, comment, attachment}
    end

    test "adds a comment with an attached file and lists it under the comment",
         %{conn: conn, user: user} do
      {:ok, user} = Kanban.Accounts.update_user_name(user, %{name: "Ada Lovelace"})
      {board, task} = board_with_task(user)
      view = open_task_view(conn, board, task)

      assert has_element?(view, composer(task) <> ~s([phx-change="validate"]))
      assert has_element?(view, composer(task) <> ~s( input[type="file"]))
      assert has_element?(view, composer(task) <> " label[phx-drop-target]", "Attach files")

      stage(view, composer(task), [notes()])
      assert has_element?(view, composer(task) <> " progress")
      post_comment(view, composer(task), "See the notes")

      assert [comment] = Repo.all(TaskComment)
      assert [attachment] = Repo.all(TaskAttachment)
      assert attachment.comment_id == comment.id
      assert attachment.uploaded_by_id == user.id

      html = view |> element(file_row(task, comment, attachment)) |> render()
      assert html =~ "notes.txt"
      assert html =~ "5 B"
      assert html =~ "Ada Lovelace"
      assert html =~ ~s(href="/attachments/#{attachment.id}/download")
      refute has_element?(view, composer(task) <> " progress")
      assert render(view) =~ "Comment added successfully"
    end

    test "a member downgraded and then restored mid-session can attach again",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      view = conn |> log_in_user(member) |> open_task_view(board, task)

      {:ok, _} = Boards.update_user_access(board, member, :read_only, owner)
      :timer.sleep(100)
      refute has_element?(view, composer(task) <> ~s( input[type="file"]))

      {:ok, _} = Boards.update_user_access(board, member, :modify, owner)
      :timer.sleep(100)
      assert has_element?(view, composer(task) <> ~s( input[type="file"]))

      stage(view, composer(task), [notes()])
      post_comment(view, composer(task), "Back again")

      assert [%{filename: "notes.txt"}] = Repo.all(TaskAttachment)
    end

    test "the composer refuses a file over the size limit with a translated error",
         %{conn: conn, user: user} do
      put_limits(max_file_bytes: 16)
      {board, task} = board_with_task(user)
      view = open_task_view(conn, board, task)

      input =
        file_input(view, composer(task), :comment_attachments, [
          %{name: "big.log", content: String.duplicate("a", 17), type: "text/plain"}
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.log")

      assert view |> element(composer(task)) |> render() =~
               AttachmentUploads.error_message(:too_large)

      post_comment(view, composer(task), "Too big")
      assert Repo.aggregate(TaskAttachment, :count) == 0
    end

    # LiveView's client drops a submit while the file input carries error
    # refs, so an enabled Add Comment would do nothing at all when clicked.
    test "Add Comment waits while a staged file has an error, and says why",
         %{conn: conn, user: user} do
      put_limits(max_file_bytes: 16)
      {board, task} = board_with_task(user)
      view = open_task_view(conn, board, task)
      button = composer(task) <> " button[type='submit']"

      refute has_element?(view, button <> "[disabled]")

      file_input(view, composer(task), :comment_attachments, [
        %{name: "big.log", content: String.duplicate("a", 17), type: "text/plain"}
      ])
      |> render_upload("big.log")

      assert has_element?(view, button <> "[disabled]")

      assert view |> element(thread(task) <> "-attach-blocked") |> render() =~
               "Cancel the files marked with an error to upload the others."

      view |> element(composer(task) <> ~s( button[phx-click="cancel-upload"])) |> render_click()

      refute has_element?(view, button <> "[disabled]")
      refute has_element?(view, thread(task) <> "-attach-blocked")
    end

    # The per-task limit counts every file on the task, the task's own included.
    test "Add Comment waits while more files are staged than the task has room for",
         %{conn: conn, user: user} do
      put_limits(max_files_per_task: 2)
      {board, task} = board_with_task(user)
      attachment_fixture(task, %{uploaded_by: user})
      view = open_task_view(conn, board, task)
      button = composer(task) <> " button[type='submit']"

      stage(view, composer(task), [notes(), %{notes() | name: "more.txt"}])

      assert has_element?(view, button <> "[disabled]")

      assert view |> element(thread(task) <> "-attach-blocked") |> render() =~
               "This task has room for 1 more file. Cancel some files to upload the rest."
    end

    test "a full task offers no file drop zone but still takes a comment",
         %{conn: conn, user: user} do
      put_limits(max_files_per_task: 1)
      {board, task} = board_with_task(user)
      attachment_fixture(task, %{uploaded_by: user})
      view = open_task_view(conn, board, task)

      refute has_element?(view, composer(task) <> " label[phx-drop-target]")

      assert view |> element(thread(task) <> "-attach-full") |> render() =~
               "A task can hold at most 1 file. Delete a file to upload another."

      refute has_element?(view, composer(task) <> " button[type='submit'][disabled]")
      post_comment(view, composer(task), "No file needed")
      assert [%TaskComment{content: "No file needed"}] = Repo.all(TaskComment)
    end

    test "cancelling a staged file in the composer stores nothing for it",
         %{conn: conn, user: user} do
      {board, task} = board_with_task(user)
      view = open_task_view(conn, board, task)

      stage(view, composer(task), [notes()])
      assert view |> element(composer(task)) |> render() =~ "notes.txt"

      view |> element(composer(task) <> ~s( button[phx-click="cancel-upload"])) |> render_click()
      refute view |> element(composer(task)) |> render() =~ "notes.txt"

      post_comment(view, composer(task), "No file after all")

      assert [%TaskComment{}] = Repo.all(TaskComment)
      assert Repo.aggregate(TaskAttachment, :count) == 0
    end

    test "a rejected comment keeps the staged files and stores nothing",
         %{conn: conn, user: user} do
      {board, task} = board_with_task(user)
      view = open_task_view(conn, board, task)

      stage(view, composer(task), [notes()])
      post_comment(view, composer(task), "")

      assert Repo.aggregate(TaskComment, :count) == 0
      assert Repo.aggregate(TaskAttachment, :count) == 0
      assert view |> element(composer(task)) |> render() =~ "notes.txt"

      post_comment(view, composer(task), "Now with text")

      assert [comment] = Repo.all(TaskComment)

      assert [%TaskAttachment{filename: "notes.txt", comment_id: comment_id}] =
               Repo.all(TaskAttachment)

      assert comment_id == comment.id
    end

    test "keeps the comment and flashes the failed file names when storing an attachment fails",
         %{conn: conn, user: user} do
      put_limits(max_files_per_task: 2)
      {board, task} = board_with_task(user)
      attachment_fixture(task, %{uploaded_by: user})
      view = open_task_view(conn, board, task)

      stage(view, composer(task), [%{name: "third.txt", content: "three", type: "text/plain"}])
      # The last slot fills behind the open view, with no broadcast.
      attachment_fixture(task, %{uploaded_by: user})
      post_comment(view, composer(task), "Here is the third file")

      assert [%TaskComment{content: "Here is the third file"}] = Repo.all(TaskComment)
      assert Repo.aggregate(TaskAttachment, :count) == 2

      html = render(view)
      assert html =~ "Comment added successfully"
      assert html =~ "Could not upload third.txt"
      assert html =~ AttachmentUploads.error_message(:too_many_files)
    end

    test "stores the files that fit and names the one that does not",
         %{conn: conn, user: user} do
      put_limits(max_files_per_task: 2)
      {board, task} = board_with_task(user)
      attachment_fixture(task, %{uploaded_by: user})
      view = open_task_view(conn, board, task)

      stage(view, composer(task), [
        %{name: "a.txt", content: "one", type: "text/plain"},
        %{name: "b.txt", content: "two", type: "text/plain"}
      ])

      post_comment(view, composer(task), "Two files")

      assert [comment] = Repo.all(TaskComment)
      assert [stored] = TaskAttachment |> Repo.all() |> Enum.reject(&is_nil(&1.comment_id))
      assert stored.comment_id == comment.id

      [refused] = ["a.txt", "b.txt"] -- [stored.filename]
      assert render(view) =~ "Could not upload #{refused}"
    end

    # docs/attachments.md: the board's owner (an org-admin counts) can delete
    # any file, so they can take one down without wiping the author's text.
    test "the board owner can delete a file on a member's comment without editing it",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      {_author, comment, attachment} = comment_with_file(board, owner, task)

      owner_view = open_task_view(conn, board, task)
      button = file_row(task, comment, attachment) <> " " <> remove_button()
      assert has_element?(owner_view, button)
      assert owner_view |> element(button) |> render() =~ "data-confirm"

      owner_view |> element(button) |> render_click()

      refute Repo.get(TaskAttachment, attachment.id)
      refute has_element?(owner_view, file_row(task, comment, attachment))
      assert render(owner_view) =~ "Attachment deleted"
      assert Repo.get(TaskComment, comment.id)
    end

    test "another member cannot remove a file on someone else's comment, even by a forged event",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      {_author, comment, attachment} = comment_with_file(board, owner, task)
      bystander = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, bystander, :modify, owner)

      view = conn |> log_in_user(bystander) |> open_task_view(board, task)
      assert has_element?(view, file_row(task, comment, attachment))
      refute has_element?(view, remove_button())

      view
      |> with_target(thread(task))
      |> render_click("remove_comment_attachment", %{"id" => to_string(attachment.id)})

      assert render(view) =~ "You are not allowed to change this comment"
      assert Repo.get(TaskAttachment, attachment.id)
    end

    test "the author removes a file on their comment while editing it",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      {author, comment, attachment} = comment_with_file(board, owner, task)

      author_view = conn |> log_in_user(author) |> open_task_view(board, task)
      refute has_element?(author_view, remove_button())

      author_view
      |> element(row(task, comment) <> ~s( button[phx-click="edit_comment"]))
      |> render_click()

      author_view
      |> element(file_row(task, comment, attachment) <> " " <> remove_button())
      |> render_click()

      refute Repo.get(TaskAttachment, attachment.id)
      assert render(author_view) =~ "Attachment deleted"
      assert Repo.get(TaskComment, comment.id)
    end

    test "removing an attachment from a comment deleted in another session shows the comment-gone flash",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      {author, comment, attachment} = comment_with_file(board, owner, task)
      view = conn |> log_in_user(author) |> open_task_view(board, task)

      view
      |> element(row(task, comment) <> ~s( button[phx-click="edit_comment"]))
      |> render_click()

      # Deleted behind the thread's back, as by another session whose
      # broadcast has not arrived yet.
      Repo.delete!(comment)

      view
      |> element(file_row(task, comment, attachment) <> " " <> remove_button())
      |> render_click()

      assert render(view) =~ "This comment no longer exists"
      refute has_element?(view, row(task, comment))
    end

    test "deleting a comment removes its attachments from the thread and their downloads 404",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      {author, comment, attachment} = comment_with_file(board, owner, task)
      view = open_task_view(conn, board, task)

      assert has_element?(view, file_row(task, comment, attachment))

      view
      |> element(row(task, comment) <> ~s( button[phx-click="delete_comment"]))
      |> render_click()

      refute has_element?(view, file_row(task, comment, attachment))
      refute Repo.get(TaskAttachment, attachment.id)

      for user <- [owner, author] do
        conn =
          build_conn() |> log_in_user(user) |> get(~p"/attachments/#{attachment.id}/download")

        assert conn.status == 404
      end
    end

    test "the composer shows the inline LockedFeature and no file input on a free board",
         %{conn: conn, user: owner} do
      enforce_plans()
      {board, task} = board_with_task(owner)
      {_author, _comment, attachment} = comment_with_file(board, owner, task)
      view = open_task_view(conn, board, task)

      lock = thread(task) <> ~s(-attach-lock[data-locked-feature="attachments"])
      assert has_element?(view, lock)
      assert has_element?(view, composer(task))
      refute has_element?(view, composer(task) <> ~s( input[type="file"]))
      refute view |> element(thread(task)) |> render() =~ attachment.filename

      view
      |> with_target(thread(task))
      |> render_click("remove_comment_attachment", %{"id" => to_string(attachment.id)})

      assert render(view) =~ AttachmentUploads.error_message({:plan_required, :attachments})
      assert Repo.get(TaskAttachment, attachment.id)
    end

    test "a read-only member gets no file input and no locked notice",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      view = conn |> log_in_user(reader) |> open_task_view(board, task)

      assert has_element?(view, composer(task))
      refute has_element?(view, composer(task) <> ~s( input[type="file"]))
      refute has_element?(view, thread(task) <> "-attach-lock")
    end

    test "another session's comment attachment appears on its attachment broadcast",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      author = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, author, :modify, owner)

      {:ok, comment} =
        author |> Scope.for_user() |> Tasks.create_comment(task, %{"content" => "See log"})

      view = open_task_view(conn, board, task)
      assert has_element?(view, row(task, comment))

      # The fixture broadcasts nothing, so only the attachment broadcast below
      # can make the thread list the file.
      attachment = attachment_fixture(task, %{comment: comment, uploaded_by: author})
      _ = render(view)
      refute has_element?(view, file_row(task, comment, attachment))

      send(
        view.pid,
        {Kanban.Attachments, :attachment_changed, %{task_id: task.id, board_id: board.id}}
      )

      # The handle_info's send_update is processed after it; the first render
      # drains the queue.
      _ = render(view)
      assert has_element?(view, file_row(task, comment, attachment))
    end

    test "the view and form hosts keep their uploads and ids apart for the same task",
         %{conn: conn, user: owner} do
      {board, task} = board_with_task(owner)
      view = open_task_view(conn, board, task)
      {:ok, form, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
      form_thread = "#" <> CommentThreadComponent.dom_id(:form, task.id)

      stage(form, form_thread <> "-composer", [notes()])
      refute view |> element(composer(task)) |> render() =~ "notes.txt"

      post_comment(form, form_thread <> "-composer", "Posted from the form")

      assert [comment] = Repo.all(TaskComment)
      assert [attachment] = Repo.all(TaskAttachment)
      assert attachment.comment_id == comment.id

      # The form host lists it under its own ids; the view host picks it up
      # from the broadcasts under the view host's ids.
      form_file = form_thread <> "-comment-#{comment.id}-attachments-attachment-#{attachment.id}"
      assert has_element?(form, form_file)
      _ = render(view)
      _ = render(view)
      assert has_element?(view, file_row(task, comment, attachment))
      refute has_element?(view, form_file)
    end

    test "the edit-form host thread also accepts comment attachments",
         %{conn: conn, user: user} do
      {board, task} = board_with_task(user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
      form_thread = "#" <> CommentThreadComponent.dom_id(:form, task.id)

      stage(view, form_thread <> "-composer", [notes()])
      post_comment(view, form_thread <> "-composer", "From the form")

      assert [comment] = Repo.all(TaskComment)
      assert [attachment] = Repo.all(TaskAttachment)
      assert attachment.comment_id == comment.id

      file =
        form_thread <>
          "-comment-#{comment.id}-attachments-attachment-#{attachment.id}"

      assert view |> element(file) |> render() =~ "notes.txt"
    end
  end

  defp put_limits(limits), do: Application.put_env(:kanban, Limits, limits)
end
