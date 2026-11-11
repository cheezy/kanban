defmodule Kanban.Organizations.OrgAdminNoticeTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Organizations.OrgAdminNotice
  alias Kanban.Organizations.OrganizationMember

  describe "deliver/2" do
    test "emails the user with the name of the membership's Organization" do
      organization = organization_fixture()
      user = user_fixture()
      membership = %OrganizationMember{organization_id: organization.id, user_id: user.id}

      assert {:ok, email} = OrgAdminNotice.deliver(user, membership)

      assert email.subject == "You're now an org-admin of #{organization.name} on Stride"
      assert email.html_body =~ "<strong>#{organization.name}</strong>"
      assert_email_sent(email)
    end

    test "raises for an Organization that no longer exists" do
      user = user_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        OrgAdminNotice.deliver(user, %OrganizationMember{organization_id: -1})
      end
    end
  end
end
