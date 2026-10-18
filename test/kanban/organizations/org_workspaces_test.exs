defmodule Kanban.Organizations.OrgWorkspacesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrgWorkspaces
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @created [:kanban, :organization, :workspace_created]
  @renamed [:kanban, :organization, :workspace_renamed]
  @archived [:kanban, :organization, :workspace_archived]

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)

    %{organization: organization, org_admin: org_admin}
  end

  defp put_board_in(workspace, user) do
    user
    |> board_fixture()
    |> Ecto.Changeset.change(workspace_id: workspace.id)
    |> Repo.update!()
  end

  defp org_workspaces(organization) do
    from(w in Workspace, where: w.organization_id == ^organization.id) |> Repo.all()
  end

  defp owner_rows(workspace) do
    from(m in WorkspaceMember, where: m.workspace_id == ^workspace.id) |> Repo.all()
  end

  # The workspace name never reaches the audit row, under any key.
  defp refute_name_in(event) do
    assert event.metadata |> Map.keys() |> Enum.filter(&String.contains?(&1, "name")) == []
  end

  defp refute_reported(event, action, actor) do
    refute_received {:telemetry_event, ^event, _, _}
    assert AuditLog.list_events(action: action, actor_user_id: actor.id) == []
  end

  describe "list_workspaces/2" do
    test "lists the Organization's unarchived workspaces by name", %{
      organization: organization,
      org_admin: org_admin
    } do
      beta = org_workspace_fixture(organization, %{name: "Beta"})
      alpha = org_workspace_fixture(organization, %{name: "Alpha"})
      org_workspace_fixture(organization, %{name: "Old", archived_at: ~U[2026-01-01 00:00:00Z]})
      org_workspace_fixture(organization_fixture(), %{name: "Foreign"})

      assert [alpha.id, beta.id] ==
               org_admin |> OrgWorkspaces.list_workspaces(organization.id) |> Enum.map(& &1.id)
    end

    test "sorts names without regard to case", %{organization: organization, org_admin: org_admin} do
      charlie = org_workspace_fixture(organization, %{name: "Charlie"})
      beta = org_workspace_fixture(organization, %{name: "beta"})
      alpha = org_workspace_fixture(organization, %{name: "Alpha"})

      assert [alpha.id, beta.id, charlie.id] ==
               org_admin |> OrgWorkspaces.list_workspaces(organization.id) |> Enum.map(& &1.id)
    end

    test "never lists a personal workspace", %{organization: organization, org_admin: org_admin} do
      assert %Workspace{personal: true} = personal_workspace_fixture(org_admin)
      assert OrgWorkspaces.list_workspaces(org_admin, organization.id) == []
    end

    test "returns nothing to a member or an org-admin of another Organization", %{
      organization: organization
    } do
      org_workspace_fixture(organization)
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      assert OrgWorkspaces.list_workspaces(member, organization.id) == []
      assert OrgWorkspaces.list_workspaces(other_admin, organization.id) == []
    end
  end

  describe "create_workspace/3" do
    test "creates an org workspace with no owner row and reports it", %{
      organization: organization,
      org_admin: org_admin
    } do
      attach_telemetry(@created)

      assert {:ok, %Workspace{} = workspace} =
               OrgWorkspaces.create_workspace(org_admin, organization.id, %{"name" => " Design "})

      assert workspace.name == "Design"
      assert workspace.organization_id == organization.id
      refute workspace.personal
      assert is_nil(workspace.archived_at)
      assert owner_rows(workspace) == []

      assert_received {:telemetry_event, @created, %{count: 1}, metadata}
      assert metadata == %{organization_id: organization.id, workspace_id: workspace.id}

      assert [event] = AuditLog.list_events(action: :org_workspace_created)
      assert event.actor_user_id == org_admin.id
      assert event.organization_id == organization.id
      assert event.metadata["workspace_id"] == workspace.id
      refute_name_in(event)
    end

    test "ignores personal, organization_id and slug in the attrs", %{
      organization: organization,
      org_admin: org_admin
    } do
      other = organization_fixture()

      assert {:ok, workspace} =
               OrgWorkspaces.create_workspace(org_admin, organization.id, %{
                 "name" => "Ops",
                 "personal" => true,
                 "organization_id" => other.id,
                 "slug" => "chosen"
               })

      assert workspace.organization_id == organization.id
      refute workspace.personal
      refute workspace.slug == "chosen"
    end

    test "allows two workspaces with the same name, with different slugs", %{
      organization: organization,
      org_admin: org_admin
    } do
      assert {:ok, first} =
               OrgWorkspaces.create_workspace(org_admin, organization.id, %{name: "Ops"})

      assert {:ok, second} =
               OrgWorkspaces.create_workspace(org_admin, organization.id, %{name: "Ops"})

      assert first.name == second.name
      refute first.slug == second.slug
    end

    test "rejects a blank or overlong name and reports nothing", %{
      organization: organization,
      org_admin: org_admin
    } do
      attach_telemetry(@created)

      for attrs <- [%{"name" => "   "}, %{"name" => String.duplicate("a", 101)}, %{}] do
        assert {:error, %Ecto.Changeset{errors: errors}} =
                 OrgWorkspaces.create_workspace(org_admin, organization.id, attrs)

        assert Keyword.has_key?(errors, :name)
      end

      refute_reported(@created, :org_workspace_created, org_admin)
      assert OrgWorkspaces.list_workspaces(org_admin, organization.id) == []
    end

    test "refuses a member, a free user and an org-admin of another Organization", %{
      organization: organization
    } do
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)
      attach_telemetry(@created)

      for actor <- [member, user_fixture(), other_admin] do
        assert {:error, :unauthorized} =
                 OrgWorkspaces.create_workspace(actor, organization.id, %{"name" => "X"})

        refute_reported(@created, :org_workspace_created, actor)
      end

      assert org_workspaces(organization) == []
    end

    test "refuses an org-admin whose role was removed since they loaded the page", %{
      organization: organization,
      org_admin: org_admin
    } do
      OrganizationMember |> Repo.get_by!(user_id: org_admin.id) |> Repo.delete!()

      assert {:error, :unauthorized} =
               OrgWorkspaces.create_workspace(org_admin, organization.id, %{"name" => "X"})
    end
  end

  describe "rename_workspace/3" do
    test "renames the workspace and reports it", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Old name"})
      attach_telemetry(@renamed)

      assert {:ok, renamed} =
               OrgWorkspaces.rename_workspace(org_admin, to_string(workspace.id), %{
                 "name" => "New name"
               })

      assert renamed.name == "New name"
      assert renamed.slug == workspace.slug
      assert_received {:telemetry_event, @renamed, %{count: 1}, metadata}
      assert metadata == %{organization_id: organization.id, workspace_id: workspace.id}

      assert [event] = AuditLog.list_events(action: :org_workspace_renamed)
      assert event.actor_user_id == org_admin.id
      assert event.organization_id == organization.id
      assert event.metadata["workspace_id"] == workspace.id
      refute_name_in(event)
    end

    test "a rename to the same name saves and reports nothing", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Same"})
      attach_telemetry(@renamed)

      assert {:ok, %Workspace{name: "Same"}} =
               OrgWorkspaces.rename_workspace(org_admin, workspace.id, %{"name" => "Same"})

      refute_reported(@renamed, :org_workspace_renamed, org_admin)
    end

    test "rejects an empty or overlong name and changes nothing", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      attach_telemetry(@renamed)

      for name <- ["", String.duplicate("b", 101)] do
        assert {:error, %Ecto.Changeset{errors: errors}} =
                 OrgWorkspaces.rename_workspace(org_admin, workspace.id, %{"name" => name})

        assert Keyword.has_key?(errors, :name)
      end

      assert Repo.get!(Workspace, workspace.id).name == "Kept"
      refute_reported(@renamed, :org_workspace_renamed, org_admin)
    end

    test "a foreign, personal, archived, unknown or malformed id is not found", %{
      organization: organization,
      org_admin: org_admin
    } do
      foreign = org_workspace_fixture(organization_fixture(), %{name: "Foreign"})
      personal = personal_workspace_fixture(org_admin)

      archived =
        org_workspace_fixture(organization, %{name: "Gone", archived_at: ~U[2026-01-01 00:00:00Z]})

      attach_telemetry(@renamed)

      for id <- [
            foreign.id,
            personal.id,
            archived.id,
            -1,
            0,
            9_223_372_036_854_775_808,
            "abc",
            "1 OR 1=1",
            nil
          ] do
        assert {:error, :not_found} =
                 OrgWorkspaces.rename_workspace(org_admin, id, %{"name" => "Mine"}),
               inspect(id)
      end

      assert Repo.get!(Workspace, foreign.id).name == "Foreign"
      assert Repo.get!(Workspace, personal.id).name == personal.name
      assert Repo.get!(Workspace, archived.id).name == "Gone"
      refute_reported(@renamed, :org_workspace_renamed, org_admin)
    end

    test "refuses a member of the Organization", %{organization: organization} do
      workspace = org_workspace_fixture(organization, %{name: "Kept"})
      member = user_fixture()
      organization_member_fixture(organization, member, :member)

      assert {:error, :unauthorized} =
               OrgWorkspaces.rename_workspace(member, workspace.id, %{"name" => "Taken"})

      assert Repo.get!(Workspace, workspace.id).name == "Kept"
    end
  end

  describe "archive_workspace/2" do
    test "sets archived_at on an empty workspace and reports it", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization)
      attach_telemetry(@archived)

      assert {:ok, %Workspace{archived_at: %DateTime{}} = archived} =
               OrgWorkspaces.archive_workspace(org_admin, workspace.id)

      assert archived.id == workspace.id
      assert Repo.get!(Workspace, workspace.id).archived_at
      assert OrgWorkspaces.list_workspaces(org_admin, organization.id) == []

      assert_received {:telemetry_event, @archived, %{count: 1}, metadata}
      assert metadata == %{organization_id: organization.id, workspace_id: workspace.id}

      assert [event] = AuditLog.list_events(action: :org_workspace_archived)
      assert event.actor_user_id == org_admin.id
      assert event.organization_id == organization.id
      assert event.metadata["workspace_id"] == workspace.id
      refute_name_in(event)
    end

    test "is refused while the workspace holds boards", %{
      organization: organization,
      org_admin: org_admin
    } do
      workspace = org_workspace_fixture(organization)
      put_board_in(workspace, org_admin)
      attach_telemetry(@archived)

      assert {:error, :workspace_has_boards} =
               OrgWorkspaces.archive_workspace(org_admin, workspace.id)

      assert is_nil(Repo.get!(Workspace, workspace.id).archived_at)
      refute_reported(@archived, :org_workspace_archived, org_admin)
    end

    test "archiving an already archived workspace is not found and changes nothing", %{
      organization: organization,
      org_admin: org_admin
    } do
      archived_at = ~U[2026-01-01 00:00:00Z]
      workspace = org_workspace_fixture(organization, %{archived_at: archived_at})

      assert {:error, :not_found} = OrgWorkspaces.archive_workspace(org_admin, workspace.id)
      assert Repo.get!(Workspace, workspace.id).archived_at == archived_at
    end

    test "a foreign or personal workspace is not found and is left unarchived", %{
      org_admin: org_admin
    } do
      foreign = org_workspace_fixture(organization_fixture())
      personal = personal_workspace_fixture(org_admin)
      attach_telemetry(@archived)

      for workspace <- [foreign, personal] do
        assert {:error, :not_found} = OrgWorkspaces.archive_workspace(org_admin, workspace.id)
        assert is_nil(Repo.get!(Workspace, workspace.id).archived_at)
      end

      refute_reported(@archived, :org_workspace_archived, org_admin)
    end

    test "refuses a non-org-admin", %{organization: organization} do
      workspace = org_workspace_fixture(organization)
      member = user_fixture()
      organization_member_fixture(organization, member, :member)

      assert {:error, :unauthorized} = OrgWorkspaces.archive_workspace(member, workspace.id)

      assert {:error, :unauthorized} =
               OrgWorkspaces.archive_workspace(user_fixture(), workspace.id)

      assert is_nil(Repo.get!(Workspace, workspace.id).archived_at)
    end
  end

  describe "change_workspace/2" do
    test "returns an unsaved changeset" do
      assert %Ecto.Changeset{valid?: false} = OrgWorkspaces.change_workspace()

      assert %Ecto.Changeset{valid?: true} =
               OrgWorkspaces.change_workspace(%Workspace{}, %{"name" => "Fine"})
    end
  end
end
