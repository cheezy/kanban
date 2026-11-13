defmodule KanbanWeb.OrgLive.OrgAdminCheckTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias KanbanWeb.OrgLive.OrgAdminCheck

  @refusal "You must be an org-admin of an Organization to access this page."

  setup do
    org = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(org, org_admin, :org_admin)

    %{org: org, org_admin: org_admin}
  end

  # The socket an Organization page holds after mount: the scope loaded then,
  # which goes stale, and the Organization the gate assigned.
  defp socket(user, org, assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      router: KanbanWeb.Router,
      assigns:
        Map.merge(
          %{__changed__: %{}, current_scope: Scope.for_user(user), organization: org, flash: %{}},
          assigns
        ),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }
  end

  defp assert_refused({:noreply, socket}, user_id) do
    assert socket.redirected == {:redirect, %{to: "/boards", status: 302}}
    assert Phoenix.Flash.get(socket.assigns.flash, :error) == @refusal

    assert [action: :permission_denied]
           |> AuditLog.list_events()
           |> Enum.any?(
             &(&1.metadata["user_id"] == user_id and &1.metadata["gate"] == "require_org_admin")
           )

    socket
  end

  defp demote(user) do
    from(m in OrganizationMember, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: :member])
  end

  defp disable(user) do
    user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp never_runs(_actor), do: flunk("the function must not run for a refused actor")

  describe "with_org_admin/3" do
    test "runs a 1-arity function with the re-read actor", %{org: org, org_admin: org_admin} do
      # A stale name in the mount-time scope shows the actor is read again.
      stale = Map.put(org_admin, :name, "stale name")

      assert {:ran, %User{} = actor} =
               stale |> socket(org) |> OrgAdminCheck.with_org_admin(&{:ran, &1})

      assert actor.id == org_admin.id
      assert actor.name == org_admin.name
      assert AuditLog.list_events(action: :permission_denied) == []
    end

    test "runs a 2-arity function with the actor and the organization id",
         %{org: org, org_admin: org_admin} do
      assert {:ran, %User{id: id}, organization_id} =
               org_admin
               |> socket(org)
               |> OrgAdminCheck.with_org_admin(&{:ran, &1, &2})

      assert id == org_admin.id
      assert organization_id == org.id
    end

    test "refuses a member, a disabled org-admin and a deleted user",
         %{org: org, org_admin: org_admin} do
      member = user_fixture()
      organization_member_fixture(org, member)

      member
      |> socket(org)
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(member.id)

      outsider = user_fixture()

      outsider
      |> socket(org)
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(outsider.id)

      socket = socket(org_admin, org)
      disable(org_admin)

      socket
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(org_admin.id)

      deleted = user_fixture()
      organization_member_fixture(org, deleted, :org_admin)
      socket = socket(deleted, org)
      Repo.delete!(deleted)

      socket
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(deleted.id)
    end

    test "an org-admin of another Organization is refused here", %{org: org} do
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      other_admin
      |> socket(org)
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(other_admin.id)
    end

    test "including the demoted-while-open cases", %{org: org, org_admin: org_admin} do
      socket = socket(org_admin, org)
      assert {:ran, _actor} = OrgAdminCheck.with_org_admin(socket, &{:ran, &1})

      demote(org_admin)

      socket
      |> OrgAdminCheck.with_org_admin(&never_runs/1)
      |> assert_refused(org_admin.id)
    end

    test ":also returning false refuses and :on_refuse runs before the redirect",
         %{org: org, org_admin: org_admin} do
      test_pid = self()
      socket = socket(org_admin, org, %{locked?: true, new_token: "plain"})

      also = fn socket, actor ->
        send(test_pid, {:also, actor.id})
        socket.assigns.locked? == false
      end

      on_refuse = fn socket ->
        assert socket.redirected == nil
        assert Phoenix.Flash.get(socket.assigns.flash, :error) == nil
        Phoenix.Component.assign(socket, :new_token, nil)
      end

      refused =
        socket
        |> OrgAdminCheck.with_org_admin(&never_runs/1, also: also, on_refuse: on_refuse)
        |> assert_refused(org_admin.id)

      assert_received {:also, id} when id == org_admin.id
      assert refused.assigns.new_token == nil

      unlocked = socket(org_admin, org, %{locked?: false})

      assert {:ran, _actor, _org_id} =
               OrgAdminCheck.with_org_admin(unlocked, &{:ran, &1, &2}, also: also)
    end

    test ":also is not run for an actor who is no longer an org-admin",
         %{org: org, org_admin: org_admin} do
      demote(org_admin)

      org_admin
      |> socket(org)
      |> OrgAdminCheck.with_org_admin(&never_runs/1,
        also: fn _socket, _actor -> flunk(":also must not run after a failed role check") end
      )
      |> assert_refused(org_admin.id)
    end

    test "an unknown option raises rather than being ignored",
         %{org: org, org_admin: org_admin} do
      assert_raise ArgumentError, fn ->
        org_admin |> socket(org) |> OrgAdminCheck.with_org_admin(&{:ran, &1}, on_refused: & &1)
      end
    end
  end

  describe "refuse/2" do
    test "records permission_denied, flashes the refusal and redirects to /boards",
         %{org: org, org_admin: org_admin} do
      socket = org_admin |> socket(org) |> OrgAdminCheck.refuse()

      assert_refused({:noreply, socket}, org_admin.id)
    end

    test "runs :on_refuse", %{org: org, org_admin: org_admin} do
      socket =
        org_admin
        |> socket(org, %{new_token: "plain"})
        |> OrgAdminCheck.refuse(on_refuse: &Phoenix.Component.assign(&1, :new_token, nil))

      assert_refused({:noreply, socket}, org_admin.id)
      assert socket.assigns.new_token == nil
    end
  end

  describe "wiring" do
    test "no org_live module defines a private with_org_admin" do
      sources = Path.wildcard("lib/kanban_web/live/org_live/*.ex")
      assert sources != []

      for path <- sources do
        source = File.read!(path)

        refute source =~ ~r/defp (with_org_admin|refuse|authorized_actor)\(/,
               "#{path} defines its own org-admin event check"
      end

      for page <- ~w(console security sso scim) do
        path = "lib/kanban_web/live/org_live/#{page}.ex"
        assert File.read!(path) =~ "import KanbanWeb.OrgLive.OrgAdminCheck", path
      end
    end

    # The pages' own differences, through their real event handlers. An
    # org-admin is never locked out through the LiveView (membership unlocks
    # SSO), so the locked page is reached with the assign the page sets.
    test "the locked SSO page refuses an event an org-admin would otherwise pass",
         %{org: org, org_admin: org_admin} do
      org_admin
      |> socket(org, %{locked?: true})
      |> then(&KanbanWeb.OrgLive.SSO.handle_event("validate_saml", %{"saml" => %{}}, &1))
      |> assert_refused(org_admin.id)
    end

    test "a refused SCIM event clears the revealed token", %{org: org, org_admin: org_admin} do
      socket = socket(org_admin, org, %{new_token: "plain"})
      demote(org_admin)

      refused =
        socket
        |> then(&KanbanWeb.OrgLive.SCIM.handle_event("validate", %{"token" => %{}}, &1))
        |> assert_refused(org_admin.id)

      assert refused.assigns.new_token == nil
    end
  end
end
