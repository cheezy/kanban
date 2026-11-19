defmodule KanbanWeb.OrgLive.ConsoleDevicesTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @refusal "You must be an org-admin of an Organization to access this page."

  setup %{conn: conn} do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(organization, member, :member)

    %{
      conn: log_in_user(conn, org_admin),
      organization: organization,
      org_admin: org_admin,
      member: member,
      member_scope: user_scope_fixture(member)
    }
  end

  defp open_members(conn) do
    {:ok, view, _html} = live(conn, ~p"/org?section=members")
    view
  end

  defp revoked_events(admin_id),
    do: AuditLog.list_events(action: "device_revoked", actor_user_id: admin_id)

  defp revoked?(device), do: not is_nil(Repo.get!(Device, device.id).revoked_at)

  defp watching?(view, member) do
    Kanban.PubSub
    |> Registry.lookup(Revocation.user_topic(member.id))
    |> Enum.any?(fn {pid, _} -> pid == view.pid end)
  end

  defp demote(user) do
    OrganizationMember
    |> Repo.get_by!(user_id: user.id)
    |> Ecto.Changeset.change(role: :member)
    |> Repo.update!()
  end

  test "an org-admin revokes one and then all of a member's devices", ctx do
    {phone, issued} = device_with_tokens_fixture(ctx.member_scope, %{name: "Mel's phone"})
    tablet = device_fixture(ctx.member_scope, %{name: "Mel's tablet", device_class: :tablet})
    spare = device_fixture(ctx.member_scope, %{name: "Spare"})

    view = open_members(ctx.conn)
    refute has_element?(view, "#member-devices-#{ctx.member.id}")

    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    assert has_element?(view, "#member-devices-toggle-#{ctx.member.id}[aria-expanded=true]")
    assert has_element?(view, "#member-device-name-#{phone.id}", "Mel's phone")
    assert has_element?(view, "#member-device-name-#{tablet.id}", "Mel's tablet")
    assert has_element?(view, "#member-device-revoke-#{phone.id}[data-confirm]")
    assert has_element?(view, "#revoke-all-devices-#{ctx.member.id}[data-confirm]")

    view |> element("#member-device-revoke-#{phone.id}") |> render_click()

    assert render(view) =~ "Device revoked."
    refute has_element?(view, "#member-device-#{phone.id}")
    assert has_element?(view, "#member-device-#{tablet.id}")
    assert revoked?(phone)
    assert Devices.fetch_by_access_token(issued.access_token) == {:error, :invalid_token}

    view |> element("#revoke-all-devices-#{ctx.member.id}") |> render_click()

    assert render(view) =~ "2 devices revoked."
    assert revoked?(tablet) and revoked?(spare)
    assert has_element?(view, "#member-device-list-#{ctx.member.id}-empty")
    refute has_element?(view, "#revoke-all-devices-#{ctx.member.id}")

    events = revoked_events(ctx.org_admin.id)
    assert length(events) == 3
    assert Enum.all?(events, &(&1.metadata["reason"] == "org_admin"))
    assert Enum.all?(events, &(&1.metadata["device_user_id"] == ctx.member.id))

    # The toggle closes the open list.
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
  end

  test "a member with no devices shows an empty state", ctx do
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    assert has_element?(
             view,
             "#member-device-list-#{ctx.member.id}-empty",
             "This member has no phones or tablets signed in."
           )

    render_hook(view, "revoke_member_devices", %{"user_id" => to_string(ctx.member.id)})
    assert render(view) =~ "0 devices revoked."
  end

  test "a crafted revoke event from a non-admin is refused", ctx do
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    OrganizationMember
    |> Repo.get_by!(user_id: ctx.org_admin.id)
    |> Ecto.Changeset.change(role: :member)
    |> Repo.update!()

    render_hook(view, "revoke_member_device", %{"device_id" => to_string(device.id)})

    flash = assert_redirect(view, ~p"/boards")
    assert flash["error"] == @refusal
    refute revoked?(device)
    assert revoked_events(ctx.org_admin.id) == []

    assert [_ | _] =
             AuditLog.list_events(action: :permission_denied, actor_user_id: ctx.org_admin.id)
  end

  test "a crafted revoke all and list from a demoted org-admin are refused", ctx do
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)

    OrganizationMember
    |> Repo.get_by!(user_id: ctx.org_admin.id)
    |> Ecto.Changeset.change(role: :member)
    |> Repo.update!()

    render_hook(view, "revoke_member_devices", %{"user_id" => to_string(ctx.member.id)})
    assert_redirect(view, ~p"/boards")
    refute revoked?(device)

    view = open_as_admin_again(ctx)

    OrganizationMember
    |> Repo.get_by!(user_id: ctx.org_admin.id)
    |> Ecto.Changeset.change(role: :member)
    |> Repo.update!()

    render_hook(view, "show_member_devices", %{"user_id" => to_string(ctx.member.id)})
    assert_redirect(view, ~p"/boards")
  end

  defp open_as_admin_again(ctx) do
    OrganizationMember
    |> Repo.get_by!(user_id: ctx.org_admin.id)
    |> Ecto.Changeset.change(role: :org_admin)
    |> Repo.update!()

    open_members(ctx.conn)
  end

  test "a device of a user outside the Organization can't be revoked", ctx do
    outsider = user_fixture()
    organization_member_fixture(organization_fixture(), outsider, :member)
    outside_device = device_fixture(user_scope_fixture(outsider))
    loner_device = device_fixture(user_scope_fixture())

    view = open_members(ctx.conn)

    for id <- [outside_device.id, Integer.to_string(loner_device.id), "abc"] do
      html = render_hook(view, "revoke_member_device", %{"device_id" => id})
      assert html =~ "Member not found."
    end

    html = render_hook(view, "show_member_devices", %{"user_id" => to_string(outsider.id)})
    assert html =~ "Member not found."
    refute has_element?(view, "#member-devices-#{outsider.id}")

    html = render_hook(view, "revoke_member_devices", %{"user_id" => outsider.id})
    assert html =~ "Member not found."

    refute revoked?(outside_device)
    refute revoked?(loner_device)
    assert revoked_events(ctx.org_admin.id) == []
  end

  test "a member who leaves the Organization with the list open is not found", ctx do
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    OrganizationMember
    |> Repo.get_by!(user_id: ctx.member.id)
    |> Repo.delete!()

    view |> element("#member-device-revoke-#{device.id}") |> render_click()

    assert render(view) =~ "Member not found."
    refute has_element?(view, "#member-#{ctx.member.id}")
    refute revoked?(device)
  end

  test "a revoke that succeeds is reported so when the open member is gone", ctx do
    second = user_fixture()
    organization_member_fixture(ctx.organization, second, :member)
    removed_device = device_fixture(user_scope_fixture(second))
    promoted_device = device_fixture(user_scope_fixture(second))
    view = open_members(ctx.conn)

    # The open member is removed meanwhile; a device of another member is
    # still revoked, and the revoke says so.
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    OrganizationMember |> Repo.get_by!(user_id: ctx.member.id) |> Repo.delete!()

    html = render_hook(view, "revoke_member_device", %{"device_id" => removed_device.id})
    assert html =~ "Device revoked."
    refute html =~ "Member not found."
    assert revoked?(removed_device)
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
    refute has_element?(view, "#member-#{ctx.member.id}")
    refute watching?(view, ctx.member)

    # The open member is promoted meanwhile.
    third = user_fixture()
    organization_member_fixture(ctx.organization, third, :member)
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{third.id}") |> render_click()

    OrganizationMember
    |> Repo.get_by!(user_id: third.id)
    |> Ecto.Changeset.change(role: :org_admin)
    |> Repo.update!()

    html = render_hook(view, "revoke_member_device", %{"device_id" => promoted_device.id})
    assert html =~ "Device revoked."
    refute html =~ "An org-admin&#39;s devices can&#39;t be managed here."
    assert revoked?(promoted_device)
    refute has_element?(view, "#member-devices-#{third.id}")
  end

  test "removing the member whose devices are open closes their list", ctx do
    device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    assert render_hook(view, "remove_member", %{"user_id" => to_string(ctx.member.id)}) =~
             "Member removed."

    refute watching?(view, ctx.member)

    # Re-added, the member's row comes back closed, never with the old list.
    organization_member_fixture(ctx.organization, ctx.member, :member)
    other = user_fixture()
    organization_member_fixture(ctx.organization, other, :member)
    render_hook(view, "remove_member", %{"user_id" => to_string(other.id)})

    assert has_element?(view, "#member-devices-toggle-#{ctx.member.id}[aria-expanded=false]")
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
  end

  test "org-admin rows have no Devices action and a crafted one is refused", ctx do
    other_admin = user_fixture()
    organization_member_fixture(ctx.organization, other_admin, :org_admin)
    device = device_fixture(user_scope_fixture(other_admin))

    view = open_members(ctx.conn)
    refute has_element?(view, "#member-devices-toggle-#{ctx.org_admin.id}")
    refute has_element?(view, "#member-devices-toggle-#{other_admin.id}")

    html = render_hook(view, "show_member_devices", %{"user_id" => to_string(other_admin.id)})
    assert html =~ "An org-admin&#39;s devices can&#39;t be managed here."

    html = render_hook(view, "revoke_member_device", %{"device_id" => device.id})
    assert html =~ "An org-admin&#39;s devices can&#39;t be managed here."
    refute revoked?(device)
  end

  test "a device revoked on another page leaves the open list at once", ctx do
    device = device_fixture(ctx.member_scope)
    kept = device_fixture(ctx.member_scope, %{name: "Kept"})
    view = open_members(ctx.conn)
    refute watching?(view, ctx.member)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    assert watching?(view, ctx.member)

    {:ok, _} = Devices.revoke_device(ctx.member_scope, device)

    refute has_element?(view, "#member-device-#{device.id}")
    assert has_element?(view, "#member-device-#{kept.id}")

    html = render_hook(view, "revoke_member_device", %{"device_id" => to_string(device.id)})
    assert html =~ "That device was already signed out."
    refute html =~ "Device revoked."
    assert has_element?(view, "#member-device-#{kept.id}")
    assert revoked_events(ctx.org_admin.id) == []

    # Closing the list, by a section change or the toggle, stops following.
    view |> element("#settings-tab-details") |> render_click()
    view |> element("#settings-tab-members") |> render_click()
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
    refute watching?(view, ctx.member)

    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    refute watching?(view, ctx.member)
  end

  test "opening another member's devices follows only that member", ctx do
    second = user_fixture()
    organization_member_fixture(ctx.organization, second, :member)
    view = open_members(ctx.conn)

    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()
    view |> element("#member-devices-toggle-#{second.id}") |> render_click()

    refute watching?(view, ctx.member)
    assert watching?(view, second)
    assert has_element?(view, "#member-devices-#{second.id}")
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
  end

  test "a second org-admin's open list follows a revoke made in another view", ctx do
    other_admin = user_fixture()
    organization_member_fixture(ctx.organization, other_admin, :org_admin)
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)
    other_view = open_members(log_in_user(build_conn(), other_admin))

    for v <- [view, other_view],
        do: v |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    view |> element("#member-device-revoke-#{device.id}") |> render_click()

    refute has_element?(other_view, "#member-device-#{device.id}")
    assert has_element?(other_view, "#member-device-list-#{ctx.member.id}-empty")
    refute has_element?(other_view, "#revoke-all-devices-#{ctx.member.id}")
  end

  test "a demoted org-admin's open list closes quietly on a revoke elsewhere", ctx do
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)
    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    demote(ctx.org_admin)
    {:ok, _} = Devices.revoke_device(ctx.member_scope, device)

    refute has_element?(view, "#member-devices-#{ctx.member.id}")
    refute watching?(view, ctx.member)
    assert AuditLog.list_events(action: :permission_denied, actor_user_id: ctx.org_admin.id) == []
  end

  test "crafted device events with no id or a non-scalar id change nothing", ctx do
    device = device_fixture(ctx.member_scope)
    view = open_members(ctx.conn)

    for event <- ["show_member_devices", "revoke_member_device", "revoke_member_devices"] do
      render_hook(view, event, %{})
      render_hook(view, event, %{"user_id" => %{"a" => 1}, "device_id" => [device.id]})
    end

    refute revoked?(device)
    refute has_element?(view, "#member-devices-#{ctx.member.id}")
  end

  test "renders the Devices action in German", ctx do
    device_fixture(ctx.member_scope)

    {:ok, view, _html} =
      ctx.conn
      |> Plug.Conn.put_session(:locale, "de")
      |> live(~p"/org?section=members")

    view |> element("#member-devices-toggle-#{ctx.member.id}") |> render_click()

    assert has_element?(view, "#member-devices-toggle-#{ctx.member.id}", "Geräte")
    assert has_element?(view, "#revoke-all-devices-#{ctx.member.id}", "Alle widerrufen")
  end
end
