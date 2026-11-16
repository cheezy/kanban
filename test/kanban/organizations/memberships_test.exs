defmodule Kanban.Organizations.MembershipsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Memberships
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  defp disable(user) do
    user
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp unique_email(prefix), do: "#{prefix}#{System.unique_integer([:positive])}@example.com"

  describe "get_membership/1" do
    test "returns nil for a user in no Organization" do
      assert Memberships.get_membership(user_fixture()) == nil
    end

    test "returns the Organization with contact name, phone and email nil, in one query" do
      organization = organization_fixture(%{city: "Toronto", contact_phone: "+1 416 555 0100"})
      user = user_fixture()
      organization_member_fixture(organization, user, :org_admin)

      test_pid = self()
      handler_id = "memberships-query-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :repo, :query],
        fn _event, _measurements, %{source: source}, _ ->
          if self() == test_pid, do: send(test_pid, {:query, source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert %OrganizationMember{role: :org_admin, organization: %Organization{} = loaded} =
               Memberships.get_membership(user)

      assert_received {:query, "organization_members"}
      refute_received {:query, _}

      assert loaded.id == organization.id
      assert loaded.name == organization.name
      assert loaded.city == "Toronto"
      assert loaded.contact_name == nil
      assert loaded.contact_phone == nil
      assert loaded.contact_email == nil
    end
  end

  describe "org_admin?/2" do
    setup do
      organization = organization_fixture()
      org_admin = user_fixture()
      member = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, member, :member)

      %{organization: organization, org_admin: org_admin, member: member}
    end

    test "is false for a disabled org-admin and for a member, and accepts a struct or an id",
         ctx do
      assert Memberships.org_admin?(ctx.org_admin, ctx.organization)
      assert Memberships.org_admin?(ctx.org_admin, ctx.organization.id)

      refute Memberships.org_admin?(ctx.member, ctx.organization)
      refute Memberships.org_admin?(ctx.member, ctx.organization.id)
      refute Memberships.org_admin?(ctx.org_admin, organization_fixture())

      disabled = disable(ctx.org_admin)

      refute Memberships.org_admin?(disabled, ctx.organization)
      refute Memberships.org_admin?(disabled, ctx.organization.id)
      assert Memberships.member?(disabled, ctx.organization)
    end
  end

  describe "member?/2 and list_members/1" do
    test "for an Organization with no members return false and []" do
      organization = organization_fixture()
      user = user_fixture()
      organization_member_fixture(organization_fixture(), user, :member)

      refute Memberships.member?(user, organization)
      refute Memberships.member?(user, organization.id)
      assert Memberships.list_members(organization) == []
      assert Memberships.list_members(organization.id) == []
    end

    test "member?/2 is true for either role in that Organization only" do
      organization = organization_fixture()
      org_admin = user_fixture()
      member = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, member, :member)

      assert Memberships.member?(org_admin, organization)
      assert Memberships.member?(member, organization.id)
      refute Memberships.member?(member, organization_fixture())
    end
  end

  describe "list_members/1" do
    test "orders org-admins first, then by email" do
      organization = organization_fixture()
      first_member = user_fixture(%{email: unique_email("aaa")})
      second_member = user_fixture(%{email: unique_email("bbb")})
      org_admin = user_fixture(%{email: unique_email("zzz")})
      organization_member_fixture(organization, second_member, :member)
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, first_member, :member)
      organization_member_fixture(organization_fixture(), user_fixture())

      members = Memberships.list_members(organization.id)

      assert Enum.map(members, & &1.user.id) == [org_admin.id, first_member.id, second_member.id]
      assert Enum.map(members, & &1.role) == [:org_admin, :member, :member]
      assert Enum.all?(members, &match?(%User{}, &1.user))
    end
  end
end
