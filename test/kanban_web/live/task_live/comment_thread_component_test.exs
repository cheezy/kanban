defmodule KanbanWeb.TaskLive.CommentThreadComponentTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.TaskLive.CommentThreadComponent

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
end
