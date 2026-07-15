defmodule KanbanWeb.Admin.UserLive.IndexTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts

  defp promote_to_admin(user) do
    {:ok, admin} = Accounts.update_user_type(user, :admin)
    admin
  end

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = promote_to_admin(user_fixture())
    %{conn: log_in_user(conn, admin), user: admin}
  end

  describe "access control" do
    setup :register_and_log_in_user

    test "non-admin user is redirected to / with a flash error", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/admin/users")

      assert flash["error"] =~ "admin"
    end

    test "unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/admin/users")

      assert redirect_to == ~p"/users/log-in"
    end
  end

  describe "admin access" do
    setup :register_and_log_in_admin

    test "renders every user's email", %{conn: conn, user: admin} do
      other = user_fixture()

      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ admin.email
      assert html =~ other.email
    end

    test "renders the page title", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ "User Administration"
    end

    test "mount assigns the full users list", %{conn: conn, user: admin} do
      other = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      user_ids = :sys.get_state(live.pid).socket.assigns.users |> Enum.map(& &1.id)
      assert admin.id in user_ids
      assert other.id in user_ids
    end

    test "renders a user's board count, and zero for a user with no boards", %{conn: conn} do
      with_boards = user_fixture()
      _board_one = board_fixture(with_boards)
      _board_two = board_fixture(with_boards)
      without_boards = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{with_boards.id} .tabular-nums", "2")
      assert has_element?(live, "#user-#{without_boards.id} .tabular-nums", "0")
    end

    test "renders a user with a nil name without crashing", %{conn: conn} do
      user = user_fixture()
      assert user.name == nil

      {:ok, _live, html} = live(conn, ~p"/admin/users")

      assert html =~ user.email
    end

    test "renders a user's name when they have one", %{conn: conn} do
      named = user_fixture(%{name: "Ada Lovelace"})

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{named.id}", "Ada Lovelace")
    end

    # Each badge variant maps to exactly one column, so asserting on the variant
    # inside a row pins that column's rendered output:
    #   badge-success -> Confirmed: Yes    badge-error -> Disabled: Yes
    #   badge-primary -> Type: admin
    test "renders an unconfirmed user without the confirmed badge", %{conn: conn} do
      unconfirmed = unconfirmed_user_fixture()
      assert unconfirmed.confirmed_at == nil

      {:ok, live, html} = live(conn, ~p"/admin/users")

      assert html =~ unconfirmed.email
      refute has_element?(live, "#user-#{unconfirmed.id} .badge-success")
      assert has_element?(live, "#user-#{unconfirmed.id} .badge-ghost", "No")
    end

    test "renders the confirmed badge for a confirmed user", %{conn: conn} do
      user = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{user.id} .badge-success", "Yes")
    end

    test "renders the disabled badge only for a disabled user", %{conn: conn} do
      disabled = user_fixture()
      enabled = user_fixture()
      {:ok, _} = Accounts.disable_user(disabled)

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{disabled.id} .badge-error", "Yes")
      refute has_element?(live, "#user-#{enabled.id} .badge-error")
      assert has_element?(live, "#user-#{enabled.id} .badge-ghost", "No")
    end

    test "renders the admin badge only for an admin", %{conn: conn, user: admin} do
      plain = user_fixture()

      {:ok, live, _html} = live(conn, ~p"/admin/users")

      assert has_element?(live, "#user-#{admin.id} .badge-primary", "Admin")
      refute has_element?(live, "#user-#{plain.id} .badge-primary")
      assert has_element?(live, "#user-#{plain.id} .badge", "User")
    end

    test "escapes a name containing HTML metacharacters" do
      # The name changeset rejects HTML metacharacters, so a hostile name can
      # only reach the table through a direct write. Force one in to prove the
      # template escapes rather than relying on that validation alone.
      admin = promote_to_admin(user_fixture())

      # change/2 skips the name changeset's validations, which is the point.
      user_fixture()
      |> Ecto.Changeset.change(name: "<script>alert('xss')</script>")
      |> Kanban.Repo.update!()

      conn = log_in_user(Phoenix.ConnTest.build_conn(), admin)
      {:ok, _live, html} = live(conn, ~p"/admin/users")

      refute html =~ "<script>alert('xss')</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
