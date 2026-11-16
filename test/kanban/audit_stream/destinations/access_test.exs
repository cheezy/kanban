defmodule Kanban.AuditStream.Destinations.AccessTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Destinations.Access
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)

    %{
      organization: organization,
      admin: admin,
      destination: destination_fixture(organization, :https)
    }
  end

  defp disable!(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp revoke!(user) do
    OrganizationMember |> where([m], m.user_id == ^user.id) |> Repo.delete_all()
  end

  describe "authorize/1" do
    test "returns the actor and their own Organization for an enabled org-admin", ctx do
      admin_id = ctx.admin.id
      organization_id = ctx.organization.id

      assert {:ok, %User{id: ^admin_id}, ^organization_id} =
               ctx.admin |> Scope.for_user() |> Access.authorize()
    end

    test "refuses a nil scope, a disabled user, a site admin and a plain member", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member, :member)

      disabled = user_fixture()
      organization_member_fixture(ctx.organization, disabled, :org_admin)
      disable!(disabled)

      site_admin = admin_fixture()

      assert Access.authorize(nil) == {:error, :unauthorized}

      for user <- [disabled, site_admin, member, user_fixture()] do
        assert user |> Scope.for_user() |> Access.authorize() == {:error, :unauthorized}
      end
    end

    test "re-reads the user, so a scope holding a stale enabled user is refused", ctx do
      scope = Scope.for_user(ctx.admin)
      disable!(ctx.admin)

      assert Access.authorize(scope) == {:error, :unauthorized}
    end
  end

  describe "fetch/3" do
    test "finds the destination by integer or string id, with or without a lock", ctx do
      %Destination{id: id} = ctx.destination

      assert {:ok, %Destination{id: ^id}} = Access.fetch(ctx.organization.id, id)
      assert {:ok, %Destination{id: ^id}} = Access.fetch(ctx.organization.id, to_string(id))
      assert {:ok, %Destination{id: ^id}} = Access.fetch(ctx.organization.id, id, lock: true)
    end

    test "returns not_found for \"abc\", 0, -1 and 9223372036854775808", ctx do
      for id <- ["abc", 0, -1, "0", "-1", 9_223_372_036_854_775_808, "9223372036854775808", nil] do
        assert Access.fetch(ctx.organization.id, id) == {:error, :not_found}
      end

      assert Access.fetch(ctx.organization.id, 9_223_372_036_854_775_807) == {:error, :not_found}
    end

    test "returns not_found for another Organization's destination id", ctx do
      other = organization_fixture()

      assert Access.fetch(other.id, ctx.destination.id) == {:error, :not_found}
    end
  end

  describe "fetch_authorized/3" do
    test "returns the locked destination to an org-admin", ctx do
      id = ctx.destination.id

      assert {:ok, %Destination{id: ^id}} =
               Access.fetch_authorized(ctx.admin, ctx.organization.id, id)
    end

    test "answers unauthorized before saying whether the destination exists", ctx do
      revoke!(ctx.admin)

      for id <- [ctx.destination.id, ctx.destination.id + 1_000_000, "abc"] do
        assert Access.fetch_authorized(ctx.admin, ctx.organization.id, id) ==
                 {:error, :unauthorized}
      end
    end

    test "an org-admin of another Organization gets not_found for this one's destination",
         ctx do
      other = organization_fixture()
      other_admin = user_fixture()
      organization_member_fixture(other, other_admin, :org_admin)

      assert Access.fetch_authorized(other_admin, other.id, ctx.destination.id) ==
               {:error, :not_found}
    end
  end

  describe "authorize_locked/2" do
    test "is :ok for an org-admin and unauthorized once their rights are revoked", ctx do
      assert Access.authorize_locked(ctx.admin, ctx.organization.id) == :ok

      revoke!(ctx.admin)

      assert Access.authorize_locked(ctx.admin, ctx.organization.id) == {:error, :unauthorized}
    end

    test "is not_found for an Organization that does not exist", ctx do
      assert Access.authorize_locked(ctx.admin, ctx.organization.id + 1_000_000) ==
               {:error, :not_found}
    end
  end
end
