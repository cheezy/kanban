defmodule Kanban.Organizations.OrgAdminsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrgAdmins
  alias Kanban.Repo

  defp disable(user) do
    user
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  describe "count_enabled_org_admins/1" do
    test "skips disabled org-admins and returns 0 for none" do
      organization = organization_fixture()

      assert OrgAdmins.count_enabled_org_admins(organization) == 0
      assert OrgAdmins.count_enabled_org_admins(organization.id) == 0

      organization_member_fixture(organization, user_fixture(), :member)
      assert OrgAdmins.count_enabled_org_admins(organization) == 0

      first_admin = user_fixture()
      second_admin = user_fixture()
      organization_member_fixture(organization, first_admin, :org_admin)
      organization_member_fixture(organization, second_admin, :org_admin)
      organization_member_fixture(organization_fixture(), user_fixture(), :org_admin)
      assert OrgAdmins.count_enabled_org_admins(organization) == 2

      disable(second_admin)
      assert OrgAdmins.count_enabled_org_admins(organization.id) == 1

      disable(first_admin)
      assert OrgAdmins.count_enabled_org_admins(organization) == 0
    end
  end

  describe "list_enabled_org_admins/1" do
    test "returns [] for none and skips a disabled org-admin" do
      organization = organization_fixture()
      assert OrgAdmins.list_enabled_org_admins(organization) == []

      enabled = user_fixture()
      disabled = user_fixture()
      organization_member_fixture(organization, enabled, :org_admin)
      organization_member_fixture(organization, disabled, :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)
      disable(disabled)

      assert [%User{id: id}] = OrgAdmins.list_enabled_org_admins(organization.id)
      assert id == enabled.id
    end
  end
end
