defmodule KanbanWeb.Admin.MessageLive.IndexTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.MessagesFixtures

  alias Kanban.Accounts
  alias Kanban.Messages
  alias Kanban.Messages.Message

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
  end
end
