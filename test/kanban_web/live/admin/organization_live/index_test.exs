defmodule KanbanWeb.Admin.OrganizationLive.IndexTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias KanbanWeb.Admin.OrganizationLive.Index

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), user: admin}
  end

  defp disable_in_db(user) do
    user
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  describe "access control" do
    test "a regular user is redirected to / with an error flash", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/admin/organizations")

      assert flash["error"] =~ "admin"
    end

    test "an unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/organizations")
      assert to == ~p"/users/log-in"
    end

    # A disabled admin's session is refused before the LiveView mounts, so the
    # stale-scope branch of mount/3 is reached only by calling it directly.
    test "mount with a scope whose admin has since been disabled lists nothing" do
      admin = admin_fixture()
      organization_fixture()
      disabled = disable_in_db(admin)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_scope: Scope.for_user(disabled)}
      }

      assert {:ok, socket} = Index.mount(%{}, %{}, socket)
      assert socket.assigns.organizations == []
      assert socket.assigns.flash["error"] == "You must be an admin to perform this action."
    end
  end

  describe "list" do
    setup :register_and_log_in_admin

    test "renders the page title and the new-organization link", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/organizations")

      assert html =~ "Organizations"
      assert has_element?(view, ~s|#new-organization[href="/admin/organizations/new"]|)
    end

    test "shows the empty state when there are no Organizations", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organizations-empty")
      assert html =~ "No organizations yet."
      refute has_element?(view, "#organizations")
    end

    test "lists each Organization with location, contact and counts", %{conn: conn} do
      organization =
        organization_fixture(%{
          name: "Acme Widgets",
          city: "Toronto",
          country: "Canada",
          contact_name: "Ada Lovelace"
        })

      organization_member_fixture(organization, user_fixture(), :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)
      organization_member_fixture(organization, user_fixture(), :member)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      row = "#organization-#{organization.id}"
      assert has_element?(view, row, "Acme Widgets")
      assert has_element?(view, row, "Toronto, Canada")
      assert has_element?(view, row, "Ada Lovelace")
      assert has_element?(view, "#org-admin-count-#{organization.id}", "1")
      assert has_element?(view, "#member-count-#{organization.id}", "2")
    end

    test "lists every Organization, ordered by name", %{conn: conn} do
      organization_fixture(%{name: "Zeta"})
      organization_fixture(%{name: "Alpha"})

      {:ok, _view, html} = live(conn, ~p"/admin/organizations")

      assert [_, after_alpha] = String.split(html, "Alpha", parts: 2)
      assert after_alpha =~ "Zeta"
    end

    test "an Organization with no members shows zero counts", %{conn: conn} do
      organization = organization_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#org-admin-count-#{organization.id}", "0")
      assert has_element?(view, "#member-count-#{organization.id}", "0")
    end

    test "blank optional location fields render a placeholder", %{conn: conn} do
      organization = organization_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organization-#{organization.id}", "—")
    end

    test "a city with no country shows just the city", %{conn: conn} do
      organization = organization_fixture(%{city: "Lyon"})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(view, "#organization-#{organization.id} td:nth-child(2)", "Lyon")
      refute has_element?(view, "#organization-#{organization.id} td:nth-child(2)", "Lyon,")
    end

    test "a very long name renders in a wrapping cell", %{conn: conn} do
      long_name = String.duplicate("Longname", 20)
      organization = organization_fixture(%{name: long_name})

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(
               view,
               ~s|#organization-name-#{organization.id}[class*="[overflow-wrap:anywhere]"]|,
               long_name
             )
    end

    test "each row links to the edit and detail pages", %{conn: conn} do
      organization = organization_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(
               view,
               ~s|#edit-organization-#{organization.id}[href="/admin/organizations/#{organization.id}/edit"]|
             )

      assert has_element?(
               view,
               ~s|#view-organization-#{organization.id}[href="/admin/organizations/#{organization.id}"]|
             )
    end

    test "there is no delete action", %{conn: conn} do
      organization_fixture()

      {:ok, view, html} = live(conn, ~p"/admin/organizations")

      refute has_element?(view, ~s|[phx-click="delete"]|)
      refute html =~ "Delete"
    end

    test "the contact name is escaped, never rendered as HTML", %{conn: conn} do
      organization_fixture(%{contact_name: "<script>alert(1)</script>"})

      {:ok, _view, html} = live(conn, ~p"/admin/organizations")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "the edit link navigates to the edit form", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      {:ok, _form_view, html} =
        view
        |> element("#edit-organization-#{organization.id}")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Edit Organization"
    end
  end
end
