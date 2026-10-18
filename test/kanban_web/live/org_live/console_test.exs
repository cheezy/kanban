defmodule KanbanWeb.OrgLive.ConsoleTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias KanbanWeb.OrgLive.Console

  @refusal "You must be an org-admin of an Organization to access this page."

  defp named_user(name, attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> Ecto.Changeset.change(name: name)
    |> Repo.update!()
  end

  defp org_admin_setup(%{conn: conn}) do
    organization =
      organization_fixture(%{
        name: "Acme Widgets",
        address_line1: "1 King Street West",
        address_line2: "Suite 400",
        city: "Toronto",
        region: "Ontario",
        postal_code: "M5H 1A1",
        country: "Canada",
        contact_name: "Ada Contact",
        contact_phone: "+1 416 555 0100",
        contact_email: "ada@acme.test"
      })

    org_admin = named_user("Olive Admin")
    organization_member_fixture(organization, org_admin, :org_admin)

    %{conn: log_in_user(conn, org_admin), organization: organization, org_admin: org_admin}
  end

  describe "access control" do
    test "a member is redirected to /boards and the refusal is audited", %{conn: conn} do
      member = user_fixture()
      organization_member_fixture(organization_fixture(), member, :member)

      assert {:error, {:redirect, %{to: "/boards", flash: flash}}} =
               live(log_in_user(conn, member), ~p"/org")

      assert flash["error"] == @refusal

      assert [event | _] =
               AuditLog.list_events(action: :permission_denied, actor_user_id: member.id)

      assert event.metadata["gate"] == "require_org_admin"
    end

    test "a user in no Organization is redirected to /boards", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(log_in_user(conn, user_fixture()), ~p"/org")
    end

    test "a site admin who is not an org-admin is redirected to /boards", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(log_in_user(conn, admin_fixture()), ~p"/org")
    end

    test "a signed-out visitor is sent to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/org")
    end

    test "an org-admin removed while the console is open is refused on the next mount", %{
      conn: conn
    } do
      %{conn: conn, org_admin: org_admin} = org_admin_setup(%{conn: conn})
      {:ok, _view, _html} = live(conn, ~p"/org")

      OrganizationMember
      |> Repo.get_by!(user_id: org_admin.id)
      |> Repo.delete!()

      assert {:error, {:redirect, %{to: "/boards", flash: %{"error" => @refusal}}}} =
               live(conn, ~p"/org")
    end
  end

  describe "details" do
    setup :org_admin_setup

    test "shows the Organization's name, address and contact read-only", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/org")

      assert html =~ "Acme Widgets"
      assert has_element?(view, "#organization-address", "1 King Street West")
      assert has_element?(view, "#organization-address", "Suite 400")
      assert has_element?(view, "#organization-location", "Toronto, Ontario, M5H 1A1, Canada")
      assert has_element?(view, "#organization-contact-name", "Ada Contact")
      assert has_element?(view, "#organization-contact-email", "ada@acme.test")
      assert has_element?(view, "#organization-contact-phone", "+1 416 555 0100")
      refute has_element?(view, "#details form")
      refute has_element?(view, "#details input")
    end

    test "links to the Organization audit log", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org")

      assert has_element?(view, ~s(#org-audit-log-link[href="/org/audit"]), "Audit log")

      assert {:ok, _audit_view, html} =
               view |> element("#org-audit-log-link") |> render_click() |> follow_redirect(conn)

      assert html =~ "Organization audit log"
    end

    test "shows only the org-admin's own Organization and ignores an id in params", %{
      conn: conn,
      organization: organization
    } do
      other = organization_fixture(%{name: "Other Corp", contact_name: "Otto Other"})

      {:ok, view, html} = live(conn, ~p"/org?organization_id=#{other.id}&id=#{other.id}")

      assert has_element?(view, "#organization-name", organization.name)
      refute html =~ "Other Corp"
      refute html =~ "Otto Other"
    end
  end

  describe "members" do
    setup :org_admin_setup

    test "lists every member with name, email and role, org-admins first", %{
      conn: conn,
      organization: organization,
      org_admin: org_admin
    } do
      member = named_user("Mel Member")
      organization_member_fixture(organization, member, :member)
      outsider = named_user("Oscar Outsider")
      organization_member_fixture(organization_fixture(), outsider, :member)

      {:ok, view, _html} = live(conn, ~p"/org")
      html = view |> element("#settings-tab-members") |> render_click()

      assert has_element?(view, "#member-name-#{org_admin.id}", "Olive Admin")
      assert has_element?(view, "#member-email-#{org_admin.id}", org_admin.email)
      assert has_element?(view, "#member-role-#{org_admin.id}", "Org-admin")
      assert has_element?(view, "#member-name-#{member.id}", "Mel Member")
      assert has_element?(view, "#member-email-#{member.id}", member.email)
      assert has_element?(view, "#member-role-#{member.id}", "Member")
      refute html =~ "Oscar Outsider"

      [first_admin, _member] = Regex.scan(~r/id="member-(\d+)"/, html, capture: :all_but_first)
      assert first_admin == [Integer.to_string(org_admin.id)]
    end

    test "an Organization whose only member is the org-admin lists just them", %{
      conn: conn,
      org_admin: org_admin
    } do
      {:ok, view, _html} = live(conn, ~p"/org")
      view |> element("#settings-tab-members") |> render_click()

      assert has_element?(view, "#member-#{org_admin.id}")
      member_rows = Regex.scan(~r/<li/, view |> element("#member-list") |> render())
      assert length(member_rows) == 1
    end

    test "a member with no name shows a dash, and long names and emails render whole", %{
      conn: conn,
      organization: organization
    } do
      long_name = String.duplicate("Bartholomew-", 12)

      long_email =
        "#{String.duplicate("very.long.address.", 5)}#{System.unique_integer([:positive])}@example.com"

      long = named_user(long_name, %{email: long_email})
      organization_member_fixture(organization, long, :member)

      nameless =
        user_fixture()
        |> Ecto.Changeset.change(name: nil)
        |> Repo.update!()

      organization_member_fixture(organization, nameless, :member)

      {:ok, view, _html} = live(conn, ~p"/org")
      view |> element("#settings-tab-members") |> render_click()

      assert has_element?(view, "#member-name-#{long.id}", long_name)
      assert has_element?(view, "#member-email-#{long.id}", long_email)
      assert has_element?(view, "#member-name-#{nameless.id}", "—")
    end
  end

  describe "mount/3 when the Organization lookup fails" do
    test "redirects to /boards with the refusal when the user no longer administers it" do
      user = user_fixture()
      organization = organization_fixture()

      socket = %Phoenix.LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: Scope.for_user(user),
          current_organization: organization
        }
      }

      assert {:ok, socket} = Console.mount(%{}, %{}, socket)
      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/boards"}}
      assert Phoenix.Flash.get(socket.assigns.flash, :error) == @refusal
      refute Map.has_key?(socket.assigns, :organization)
    end
  end

  describe "select_section" do
    setup :org_admin_setup

    test "switches between the Details and Members sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org")

      assert has_element?(view, "#details")
      refute has_element?(view, "#members")

      view |> element("#settings-tab-members") |> render_click()
      assert_patch(view, ~p"/org?section=members")
      assert has_element?(view, "#members")
      refute has_element?(view, "#details")

      view |> element("#settings-tab-details") |> render_click()
      assert_patch(view, ~p"/org?section=details")
      assert has_element?(view, "#details")
    end

    test "?section=members opens the Members section directly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org?section=members")

      assert has_element?(view, "#members")
      assert has_element?(view, "#member-list")
      refute has_element?(view, "#details")
      assert has_element?(view, ~s|#settings-tab-members[aria-selected="true"]|)
    end

    test "an unknown or empty ?section= shows Details", %{conn: conn} do
      for query <- ["section=workspaces", "section=__struct__", "section=", "other=1"] do
        {:ok, view, _html} = live(conn, "/org?" <> query)

        assert has_element?(view, "#details"), query
        refute has_element?(view, "#members"), query
      end
    end

    test "patching back to /org with no section returns to Details", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org?section=members")

      render_patch(view, ~p"/org")

      assert has_element?(view, "#details")
      refute has_element?(view, "#members")
    end

    test "ignores an unknown or missing section name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org")

      render_hook(view, "select_section", %{"section" => "workspaces"})
      assert has_element?(view, "#details")

      render_hook(view, "select_section", %{"section" => "__struct__"})
      assert has_element?(view, "#details")

      render_hook(view, "select_section", %{})
      assert has_element?(view, "#details")
    end
  end
end
