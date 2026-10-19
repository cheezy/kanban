defmodule KanbanWeb.OrgLive.ConsoleTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
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

    test "an org-admin removed while the console is open is refused on the next tab change", %{
      conn: conn
    } do
      %{conn: conn, org_admin: org_admin} = org_admin_setup(%{conn: conn})
      {:ok, view, _html} = live(conn, ~p"/org")

      OrganizationMember
      |> Repo.get_by!(user_id: org_admin.id)
      |> Repo.delete!()

      view |> element("#settings-tab-members") |> render_click()

      assert_redirect(view, ~p"/boards")
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

  describe "workspaces" do
    setup :org_admin_setup

    defp org_workspaces(organization) do
      from(w in Workspace, where: w.organization_id == ^organization.id) |> Repo.all()
    end

    defp open_workspaces(conn) do
      {:ok, view, _html} = live(conn, ~p"/org?section=workspaces")
      view
    end

    test "the Workspaces tab opens the section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org")

      view |> element("#settings-tab-workspaces") |> render_click()

      assert_patch(view, ~p"/org?section=workspaces")
      assert has_element?(view, "#workspaces")
      assert has_element?(view, "#create-workspace-form")
    end

    test "lists the Organization's active workspaces and hides archived and foreign ones", %{
      conn: conn,
      organization: organization,
      org_admin: org_admin
    } do
      active = org_workspace_fixture(organization, %{name: "Active space"})

      archived =
        org_workspace_fixture(organization, %{
          name: "Archived space",
          archived_at: ~U[2026-01-01 00:00:00Z]
        })

      foreign = org_workspace_fixture(organization_fixture(), %{name: "Foreign space"})
      personal = personal_workspace_fixture(org_admin)

      view = open_workspaces(conn)

      assert has_element?(view, "#workspace-name-#{active.id}", "Active space")
      refute has_element?(view, "#workspace-#{archived.id}")
      refute has_element?(view, "#workspace-#{foreign.id}")
      refute has_element?(view, "#workspace-#{personal.id}")
      refute has_element?(view, "#workspaces-empty")
    end

    test "says so when the Organization has no workspaces", %{conn: conn} do
      view = open_workspaces(conn)

      assert has_element?(view, "#workspaces-empty")
      refute has_element?(view, "#workspace-list")
    end

    test "creates a workspace owned by the Organization", %{
      conn: conn,
      organization: organization
    } do
      view = open_workspaces(conn)

      view
      |> form("#create-workspace-form", workspace: %{name: "Design"})
      |> render_submit()

      assert [workspace] =
               org_workspaces(organization)

      assert workspace.name == "Design"
      refute workspace.personal
      assert has_element?(view, "#workspace-name-#{workspace.id}", "Design")
      assert render(view) =~ "Workspace created."
      assert [_event] = AuditLog.list_events(action: :org_workspace_created)
    end

    test "gives the emptied create form a fresh input after each create, so the typed name does not stay",
         %{conn: conn} do
      view = open_workspaces(conn)
      assert has_element?(view, "#create-workspace-form input#workspace-0_name")

      view
      |> form("#create-workspace-form", workspace: %{name: "Design"})
      |> render_submit()

      assert has_element?(view, "#create-workspace-form input#workspace-1_name")
      refute has_element?(view, "#create-workspace-form input#workspace-0_name")
      refute has_element?(view, "#create-workspace-form input[value=\"Design\"]")

      view
      |> form("#create-workspace-form", workspace: %{name: "Research"})
      |> render_submit()

      assert has_element?(view, "#create-workspace-form input#workspace-2_name")
    end

    test "moves focus back into the create input after a create, not on first render",
         %{conn: conn} do
      view = open_workspaces(conn)
      refute has_element?(view, "#create-workspace-form input#workspace-0_name[phx-mounted]")

      view
      |> form("#create-workspace-form", workspace: %{name: "Design"})
      |> render_submit()

      assert view
             |> element("#create-workspace-form input#workspace-1_name")
             |> render() =~ ~s(phx-mounted="[[&quot;focus&quot;)
    end

    test "keeps the create input after a rejected name, so the typed name and its error stay",
         %{conn: conn} do
      view = open_workspaces(conn)

      view
      |> form("#create-workspace-form", workspace: %{name: "  "})
      |> render_submit()

      assert has_element?(view, "#create-workspace-form input#workspace-0_name")
    end

    test "shows a blank or overlong name's error inline and creates nothing", %{
      conn: conn,
      organization: organization
    } do
      view = open_workspaces(conn)

      html =
        view
        |> form("#create-workspace-form", workspace: %{name: "  "})
        |> render_submit()

      assert html =~ "can&#39;t be blank"

      html =
        view
        |> form("#create-workspace-form", workspace: %{name: String.duplicate("x", 101)})
        |> render_submit()

      assert html =~ "should be at most 100 character(s)"
      assert org_workspaces(organization) == []
      assert AuditLog.list_events(action: :org_workspace_created) == []
    end

    test "renames a workspace", %{conn: conn, organization: organization} do
      workspace = org_workspace_fixture(organization, %{name: "Old name"})
      view = open_workspaces(conn)

      view |> element("#rename-workspace-#{workspace.id}") |> render_click()
      assert has_element?(view, "#rename-workspace-form")

      view
      |> form("#rename-workspace-form", rename: %{name: "New name"})
      |> render_submit()

      assert Repo.get!(Workspace, workspace.id).name == "New name"
      assert has_element?(view, "#workspace-name-#{workspace.id}", "New name")
      refute has_element?(view, "#rename-workspace-form")
      assert render(view) =~ "Workspace renamed."
    end

    test "saving a rename with the name unchanged says nothing changed and audits nothing", %{
      conn: conn,
      organization: organization
    } do
      workspace = org_workspace_fixture(organization, %{name: "Same name"})
      view = open_workspaces(conn)

      view |> element("#rename-workspace-#{workspace.id}") |> render_click()

      html =
        view
        |> form("#rename-workspace-form", rename: %{name: "Same name"})
        |> render_submit()

      assert html =~ "No changes to save."
      refute html =~ "Workspace renamed."
      refute has_element?(view, "#rename-workspace-form")
      assert has_element?(view, "#workspace-name-#{workspace.id}", "Same name")
      assert AuditLog.list_events(action: :org_workspace_renamed) == []
    end

    test "shows a rename's validation error inline and keeps the old name", %{
      conn: conn,
      organization: organization
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      view = open_workspaces(conn)

      view |> element("#rename-workspace-#{workspace.id}") |> render_click()

      html =
        view
        |> form("#rename-workspace-form", rename: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "#rename-workspace-form")
      assert Repo.get!(Workspace, workspace.id).name == "Kept"
    end

    test "shows a duplicate name error inline", %{conn: conn, organization: organization} do
      org_workspace_fixture(organization, %{name: "Design"})
      other = org_workspace_fixture(organization, %{name: "Other"})
      view = open_workspaces(conn)

      html =
        view
        |> form("#create-workspace-form", workspace: %{name: "design"})
        |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(view, "#create-workspace-form")
      assert length(org_workspaces(organization)) == 2

      view |> element("#rename-workspace-#{other.id}") |> render_click()

      html =
        view
        |> form("#rename-workspace-form", rename: %{name: "DESIGN"})
        |> render_submit()

      assert html =~ "has already been taken"
      assert has_element?(view, "#rename-workspace-form")
      assert Repo.get!(Workspace, other.id).name == "Other"
      assert AuditLog.list_events(action: :org_workspace_created) == []
      assert AuditLog.list_events(action: :org_workspace_renamed) == []
    end

    test "cancelling a rename restores the row", %{conn: conn, organization: organization} do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      view = open_workspaces(conn)

      view |> element("#rename-workspace-#{workspace.id}") |> render_click()
      view |> element("#cancel-workspace-rename") |> render_click()

      refute has_element?(view, "#rename-workspace-form")
      assert has_element?(view, "#workspace-name-#{workspace.id}", "Kept")
    end

    test "archives an empty workspace and hides it", %{conn: conn, organization: organization} do
      workspace = org_workspace_fixture(organization, %{name: "Empty"})
      view = open_workspaces(conn)

      view |> element("#archive-workspace-#{workspace.id}") |> render_click()

      assert Repo.get!(Workspace, workspace.id).archived_at
      refute has_element?(view, "#workspace-#{workspace.id}")
      assert render(view) =~ "Workspace archived."
    end

    test "refuses to archive a workspace that holds boards, with a message", %{
      conn: conn,
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Busy"})

      org_admin
      |> board_fixture()
      |> Ecto.Changeset.change(workspace_id: workspace.id)
      |> Repo.update!()

      view = open_workspaces(conn)
      view |> element("#archive-workspace-#{workspace.id}") |> render_click()

      assert render(view) =~
               "This workspace still holds boards. Move them out before archiving it."

      assert is_nil(Repo.get!(Workspace, workspace.id).archived_at)
      assert has_element?(view, "#workspace-#{workspace.id}")
    end

    test "crafted ids for another Organization's or a personal workspace change nothing", %{
      conn: conn,
      org_admin: org_admin
    } do
      foreign = org_workspace_fixture(organization_fixture(), %{name: "Foreign"})
      personal = personal_workspace_fixture(org_admin)
      view = open_workspaces(conn)

      for workspace <- [foreign, personal] do
        render_hook(view, "archive_workspace", %{"id" => to_string(workspace.id)})
        assert render(view) =~ "Workspace not found."

        render_hook(view, "rename_workspace", %{
          "workspace_id" => to_string(workspace.id),
          "rename" => %{"name" => "Taken"}
        })

        assert render(view) =~ "Workspace not found."

        stored = Repo.get!(Workspace, workspace.id)
        assert stored.name == workspace.name
        assert is_nil(stored.archived_at)
      end
    end

    test "a rename payload with no name is refused as blank, never reported as renamed", %{
      conn: conn,
      organization: organization
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      view = open_workspaces(conn)

      view |> element("#rename-workspace-#{workspace.id}") |> render_click()

      for params <- [%{}, %{"rename" => "not-a-map"}, %{"rename" => %{"other" => "x"}}] do
        html =
          render_hook(
            view,
            "rename_workspace",
            Map.put(params, "workspace_id", to_string(workspace.id))
          )

        assert html =~ "can&#39;t be blank"
        refute html =~ "Workspace renamed."
      end

      assert Repo.get!(Workspace, workspace.id).name == "Kept"
      assert AuditLog.list_events(action: :org_workspace_renamed) == []
    end

    test "starting a rename of a workspace that is not listed says not found", %{
      conn: conn,
      org_admin: org_admin
    } do
      foreign = org_workspace_fixture(organization_fixture(), %{name: "Foreign"})
      personal = personal_workspace_fixture(org_admin)

      for workspace <- [foreign, personal] do
        view = open_workspaces(conn)
        refute render(view) =~ "Workspace not found."

        render_hook(view, "start_rename", %{"id" => to_string(workspace.id)})

        refute has_element?(view, "#rename-workspace-form")
        assert render(view) =~ "Workspace not found."
      end
    end

    test "crafted payloads without an id or with a malformed one change nothing", %{
      conn: conn,
      organization: organization
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      view = open_workspaces(conn)

      render_hook(view, "archive_workspace", %{})
      render_hook(view, "rename_workspace", %{"rename" => %{"name" => "Taken"}})
      render_hook(view, "start_rename", %{})
      render_hook(view, "archive_workspace", %{"id" => "not-a-number"})
      render_hook(view, "create_workspace", %{"workspace" => "not-a-map"})
      render_hook(view, "start_rename", %{"id" => %{"nested" => "map"}})
      render_hook(view, "start_rename", %{"id" => ["list"]})

      stored = Repo.get!(Workspace, workspace.id)
      assert stored.name == "Kept"
      assert is_nil(stored.archived_at)
      assert has_element?(view, "#workspace-#{workspace.id}")
    end

    test "every workspace event re-checks the org-admin role from the database", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})

      events = [
        {"create_workspace", %{"workspace" => %{"name" => "New"}}},
        {"start_rename", %{"id" => to_string(workspace.id)}},
        {"cancel_rename", %{}},
        {"rename_workspace",
         %{"workspace_id" => to_string(workspace.id), "rename" => %{"name" => "Taken"}}},
        {"archive_workspace", %{"id" => to_string(workspace.id)}}
      ]

      for {event, params} <- events do
        Repo.delete_all(OrganizationMember)
        organization_member_fixture(organization, org_admin, :org_admin)
        conn = log_in_user(build_conn(), org_admin)
        view = open_workspaces(conn)

        OrganizationMember |> Repo.get_by!(user_id: org_admin.id) |> Repo.delete!()

        render_hook(view, event, params)

        assert_redirect(view, ~p"/boards")
      end

      stored = Repo.get!(Workspace, workspace.id)
      assert stored.name == "Kept"
      assert is_nil(stored.archived_at)

      assert org_workspaces(organization) == [
               stored
             ]

      denied = AuditLog.list_events(action: :permission_denied, actor_user_id: org_admin.id)
      assert length(denied) >= length(events)
    end

    test "a member demoted from org-admin cannot act through a crafted event", %{
      conn: conn,
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      view = open_workspaces(conn)

      OrganizationMember
      |> Repo.get_by!(user_id: org_admin.id)
      |> Ecto.Changeset.change(role: :member)
      |> Repo.update!()

      render_hook(view, "archive_workspace", %{"id" => to_string(workspace.id)})

      assert_redirect(view, ~p"/boards")
      assert is_nil(Repo.get!(Workspace, workspace.id).archived_at)
      assert AuditLog.list_events(action: :org_workspace_archived) == []
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
      for query <- ["section=billing", "section=__struct__", "section=", "other=1"] do
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

      render_hook(view, "select_section", %{"section" => "billing"})
      assert has_element?(view, "#details")

      render_hook(view, "select_section", %{"section" => "__struct__"})
      assert has_element?(view, "#details")

      render_hook(view, "select_section", %{})
      assert has_element?(view, "#details")
    end
  end
end
