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

  defp entry(comment, flags \\ %{}) do
    Map.merge(%{comment: comment, can_edit: false, can_delete: false}, flags)
  end

  defp comment(attrs) do
    struct(
      %TaskComment{
        id: 1,
        content: "Hello",
        author: nil,
        author_agent_name: nil,
        edited_at: nil,
        inserted_at: ~N[2024-01-15 10:30:00]
      },
      attrs
    )
  end

  defp render_row(entry, attrs \\ []) do
    render_component(&CommentThreadComponent.comment_row/1, [entry: entry] ++ attrs)
  end

  describe "comment_row/1" do
    test "renders \"Unknown\" for a comment with no author" do
      html = render_row(entry(comment(%{author: nil})))

      assert html =~ "Unknown"
      assert html =~ "Hello"
    end

    test "renders the author's name, falling back to email when the name is blank" do
      named = render_row(entry(comment(%{author: %{id: 7, name: "Ada", email: "ada@x.test"}})))
      blank = render_row(entry(comment(%{author: %{id: 7, name: "", email: "ada@x.test"}})))

      assert named =~ "Ada"
      refute named =~ "ada@x.test"
      assert blank =~ "ada@x.test"
    end

    test "renders the agent name and the via-user label for an agent comment" do
      html =
        render_row(
          entry(
            comment(%{
              author_agent_name: "Claude Opus 5.5",
              author: %{id: 7, name: "Ada", email: "ada@x.test"}
            })
          )
        )

      assert html =~ "Claude Opus 5.5"
      assert html =~ "via Ada"
    end

    test "renders the edited marker only when edited_at is present" do
      plain = render_row(entry(comment(%{})))
      edited = render_row(entry(comment(%{edited_at: ~U[2024-01-16 09:00:00Z]})))

      refute plain =~ "data-comment-edited"
      assert edited =~ "data-comment-edited"
      assert edited =~ "edited"
    end

    test "renders a relative time from the naive inserted_at" do
      inserted_at = NaiveDateTime.add(NaiveDateTime.utc_now(), -3 * 3600)
      html = render_row(entry(comment(%{inserted_at: inserted_at})))

      assert html =~ "3h ago"
      assert html =~ ~s(datetime=")
    end

    test "shows edit and delete controls only when allowed" do
      none = render_row(entry(comment(%{})))
      delete_only = render_row(entry(comment(%{}), %{can_delete: true}))
      both = render_row(entry(comment(%{}), %{can_edit: true, can_delete: true}))

      refute none =~ "edit_comment"
      refute none =~ "delete_comment"
      refute delete_only =~ "edit_comment"
      assert delete_only =~ "delete_comment"
      assert both =~ "edit_comment"
      assert both =~ "delete_comment"
    end

    test "escapes comment content and keeps a very long word wrappable" do
      long_word = String.duplicate("a", 2_000)
      html = render_row(entry(comment(%{content: "<script>alert(1)</script> " <> long_word})))

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ long_word
      assert html =~ "overflow-wrap: anywhere"
    end
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

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "add_comment",
          %{"task_comment" => %{"content" => "should not save"}},
          socket
        )

      assert socket.assigns.flash["error"] =~ "must be a board member"
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

      {:noreply, socket} =
        CommentThreadComponent.handle_event(
          "delete_comment",
          %{"id" => to_string(owners.id)},
          socket
        )

      assert socket.assigns.flash["error"] =~ "not allowed"
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

      assert socket.assigns.flash["error"] =~ "no longer exists"
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
    end
  end
end
