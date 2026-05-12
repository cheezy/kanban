defmodule KanbanWeb.Admin.MessageLive.IndexTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.MessagesFixtures

  alias Kanban.Accounts
  alias Kanban.Messages
  alias Kanban.Messages.Message
  alias KanbanWeb.Admin.MessageLive.Index

  defp promote_to_admin(user) do
    {:ok, admin} = Accounts.update_user_type(user, :admin)
    admin
  end

  defp register_and_log_in_admin(context) do
    user = user_fixture()
    admin = promote_to_admin(user)
    %{conn: conn} = Map.drop(context, [:conn]) |> Map.put(:conn, context.conn)
    %{conn: log_in_user(conn, admin), user: admin}
  end

  describe "access control" do
    setup :register_and_log_in_user

    test "non-admin user is redirected to / with a flash error", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/admin/messages")

      assert flash["error"] =~ "admin"
    end

    test "unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(conn, ~p"/admin/messages")

      assert redirect_to == ~p"/users/log-in"
    end
  end

  describe "admin access" do
    setup :register_and_log_in_admin

    test "admin user can access /admin/messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/messages")

      assert html =~ "Broadcast Messages"
      assert html =~ "Create a new message"
    end

    test "empty state is shown when there are no messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/messages")

      assert html =~ "No messages yet."
    end

    test "existing messages are listed newest first", %{conn: conn, user: admin} do
      old = message_fixture(admin, %{title: "first"})
      :timer.sleep(5)
      new = message_fixture(admin, %{title: "second"})

      {:ok, _view, html} = live(conn, ~p"/admin/messages")

      assert html =~ ~s(id="message-#{new.id}")
      assert html =~ ~s(id="message-#{old.id}")
      # Newer should appear before older in the rendered output.
      assert :binary.match(html, "message-#{new.id}") <
               :binary.match(html, "message-#{old.id}")
    end
  end

  describe "create a message" do
    setup :register_and_log_in_admin

    test "valid params insert a row and render it in the list", %{conn: conn, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      html =
        view
        |> form("#new-message-form", message: %{title: "Hello", body: "World"})
        |> render_submit()

      assert html =~ "Hello"
      assert html =~ "World"

      assert [%Message{title: "Hello", body: "World", sender_id: sender_id}] =
               Messages.list_messages()

      assert sender_id == admin.id
    end

    test "blank title shows a validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      html =
        view
        |> form("#new-message-form", message: %{title: "", body: "body"})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "successful save flashes the confirmation message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      view
      |> form("#new-message-form", message: %{title: "Heads up", body: "All quiet today"})
      |> render_submit()

      assert render(view) =~ "Message created."
    end

    test "submitting invalid params does not insert a row and re-renders form errors", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      html =
        view
        |> form("#new-message-form", message: %{title: "", body: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute html =~ "Message created."
      assert Messages.list_messages() == []
    end
  end

  describe "delete a message" do
    setup :register_and_log_in_admin

    test "removes the message from the list", %{conn: conn, user: admin} do
      message = message_fixture(admin, %{title: "todelete"})

      {:ok, view, html} = live(conn, ~p"/admin/messages")
      assert html =~ "todelete"

      html =
        view
        |> element("#message-#{message.id} button[phx-click='delete']")
        |> render_click()

      refute html =~ "todelete"
      assert Messages.list_messages() == []
    end

    test "deletes a message that already has dismissals (cascade)", %{conn: conn, user: admin} do
      reader = user_fixture()
      message = message_fixture(admin, %{title: "pending"})
      _dismissal = message_dismissal_fixture(message, reader)

      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      view
      |> element("#message-#{message.id} button[phx-click='delete']")
      |> render_click()

      assert Messages.list_messages() == []
      assert Messages.list_undismissed_for_user(reader) == []
    end

    test "successful delete flashes the confirmation message", %{conn: conn, user: admin} do
      message = message_fixture(admin, %{title: "fleeting"})

      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      view
      |> element("#message-#{message.id} button[phx-click='delete']")
      |> render_click()

      assert render(view) =~ "Message deleted."
    end

    test "deleting a non-existent id flashes 'Message not found' without crashing", %{
      conn: conn,
      user: admin
    } do
      message = message_fixture(admin, %{title: "concurrently-removed"})

      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      # Race: another tab deletes the row before this LiveView's delete event
      # fires. The handler must not crash and must surface a human-readable
      # error flash. Drive the event directly via render_hook so we exercise
      # the nil branch even after the DOM element is gone.
      {:ok, _} = Messages.delete_message(message)

      render_hook(view, "delete", %{"id" => Integer.to_string(message.id)})

      assert render(view) =~ "Message not found."
      assert Messages.list_messages() == []
    end

    test "delete event with non-integer id does not crash (W400/W401)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      render_hook(view, "delete", %{"id" => "not-an-integer"})

      assert render(view) =~ "Message not found."
    end
  end

  describe "W400 per-event admin guards (defense-in-depth)" do
    # Even though the on_mount hook stops non-admins from reaching the
    # LiveView, the per-event guard is a third defense layer in case the
    # router or on_mount declarations are ever altered. These tests exercise
    # the guard logic directly by mounting a socket as admin, then swapping
    # current_scope.user.type to :user before each render_hook to simulate
    # a stale or tampered scope.

    setup :register_and_log_in_admin

    test "save event for a non-admin scope is rejected by the guard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      :sys.replace_state(view.pid, fn state ->
        scope = state.socket.assigns.current_scope
        non_admin_user = %{scope.user | type: :user}
        new_scope = %{scope | user: non_admin_user}
        put_in(state.socket.assigns.current_scope, new_scope)
      end)

      render_hook(view, "save", %{"message" => %{"title" => "x", "body" => "x"}})

      assert render(view) =~ "admin"
      assert Messages.list_messages() == []
    end

    test "delete event for a non-admin scope is rejected by the guard",
         %{conn: conn, user: admin} do
      m = message_fixture(admin, %{title: "guard-test"})
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      :sys.replace_state(view.pid, fn state ->
        scope = state.socket.assigns.current_scope
        non_admin_user = %{scope.user | type: :user}
        new_scope = %{scope | user: non_admin_user}
        put_in(state.socket.assigns.current_scope, new_scope)
      end)

      render_hook(view, "delete", %{"id" => Integer.to_string(m.id)})

      assert render(view) =~ "admin"
      assert Enum.any?(Messages.list_messages(), &(&1.id == m.id))
    end

    test "validate event for a non-admin scope is rejected by the guard",
         %{conn: conn} do
      # Covers the per-event guard on the "validate" phx-change handler. This
      # path was previously only exercised on save/delete; adding it for full
      # coverage of the W400 defense.
      {:ok, view, _html} = live(conn, ~p"/admin/messages")

      :sys.replace_state(view.pid, fn state ->
        scope = state.socket.assigns.current_scope
        non_admin_user = %{scope.user | type: :user}
        new_scope = %{scope | user: non_admin_user}
        put_in(state.socket.assigns.current_scope, new_scope)
      end)

      render_hook(view, "validate", %{"message" => %{"title" => "x", "body" => "y"}})

      assert render(view) =~ "admin"
    end
  end

  describe "fetch_message/1 defensive id parser" do
    # The LiveView's phx-value-id attributes always serialize as strings, so
    # the integer and non-binary heads are defensive clauses that the
    # event-driven tests do not naturally reach. These targeted tests pin the
    # contract: integer in → record (or nil); non-binary non-integer in → nil.

    test "looks up a message by an integer id directly" do
      admin = promote_to_admin(user_fixture())
      message = message_fixture(admin, %{title: "lookup-test"})

      assert %Message{id: id} = Index.fetch_message(message.id)
      assert id == message.id
    end

    test "returns nil for an integer id that does not match any message" do
      assert Index.fetch_message(999_999_999) == nil
    end

    test "returns nil for a non-binary, non-integer id (defensive fallthrough)" do
      assert Index.fetch_message(nil) == nil
      assert Index.fetch_message(:foo) == nil
      assert Index.fetch_message(%{id: 1}) == nil
      assert Index.fetch_message([1, 2, 3]) == nil
    end

    test "returns nil for a malformed string id" do
      assert Index.fetch_message("not-an-integer") == nil
      assert Index.fetch_message("123abc") == nil
      assert Index.fetch_message("") == nil
    end
  end
end
