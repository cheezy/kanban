defmodule KanbanWeb.UserLive.SettingsDevicesTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo

  @t0 ~U[2026-11-18 12:00:00Z]

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user, scope: user_scope_fixture(user)}
  end

  defp open_devices(conn) do
    {:ok, view, _html} = live(conn, ~p"/users/settings?section=devices")
    view
  end

  defp revoked_events(user_id),
    do: AuditLog.list_events(action: "device_revoked", actor_user_id: user_id)

  test "lists the person's devices with last seen", %{conn: conn, scope: scope} do
    seen = device_fixture(scope, %{name: "Ada's iPhone", push_token: "fixture-push-1"}, @t0)
    seen = Devices.touch_last_seen(seen, ~U[2026-11-18 13:30:00Z])

    unseen =
      device_fixture(
        scope,
        %{
          name: "Work tablet",
          platform: :android,
          client_id: "stride-android",
          device_class: :tablet
        },
        @t0
      )

    other = device_fixture(user_scope_fixture(), %{name: "Someone else's phone"}, @t0)

    view = open_devices(conn)
    html = render(view)

    assert has_element?(view, "#settings-tab-devices[aria-selected=true]")
    assert has_element?(view, "#device-name-#{seen.id}", "Ada's iPhone")
    assert has_element?(view, "#device-kind-#{seen.id}", "iOS · Phone")
    assert has_element?(view, "#device-version-#{seen.id}", "App 1.0.0 (42)")

    assert has_element?(
             view,
             "#device-last-seen-#{seen.id} time[datetime='2026-11-18T13:30:00Z']"
           )

    assert has_element?(view, "#device-kind-#{unseen.id}", "Android · Tablet")
    assert has_element?(view, "#device-last-seen-#{unseen.id}", "Never")
    assert has_element?(view, "#device-revoke-#{seen.id}[data-confirm]")
    refute has_element?(view, "#device-#{other.id}")

    refute html =~ "fixture-push-1"
    refute html =~ seen.approval_public_key
  end

  test "Revoke revokes the device and writes device_revoked with reason user", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {device, issued} = device_with_tokens_fixture(scope, %{name: "Lost phone"})
    kept = device_fixture(scope, %{name: "Kept phone"})

    view = open_devices(conn)
    view |> element("#device-revoke-#{device.id}") |> render_click()

    assert render(view) =~ "Device revoked."
    refute has_element?(view, "#device-#{device.id}")
    assert has_element?(view, "#device-#{kept.id}")

    assert %DateTime{} = Repo.get!(Device, device.id).revoked_at
    assert Devices.fetch_by_access_token(issued.access_token) == {:error, :invalid_token}

    assert [event] = revoked_events(user.id)
    assert event.metadata["reason"] == "user"
    assert event.metadata["device_id"] == device.id
  end

  test "shows an empty state when there are no devices", %{conn: conn} do
    view = open_devices(conn)

    assert has_element?(view, "#device-list-empty", "No phones or tablets are signed in")
    refute has_element?(view, "#device-list")
  end

  test "renders in German", %{conn: conn, scope: scope} do
    device = device_fixture(scope, %{device_class: :tablet}, @t0)
    phone = device_fixture(scope, %{device_class: :phone}, @t0)

    {:ok, view, html} =
      conn
      |> Plug.Conn.put_session(:locale, "de")
      |> live(~p"/users/settings?section=devices")

    refute html =~ "The phones and tablets signed in to your account"
    refute html =~ "Last seen"
    assert has_element?(view, "#settings-tab-devices", "Geräte")
    assert has_element?(view, "#device-kind-#{device.id}", "iOS · Tablet")
    # "Telefon" differs from the English label, so the class label is pinned.
    assert has_element?(view, "#device-kind-#{phone.id}", "iOS · Telefon")
    refute has_element?(view, "#device-kind-#{phone.id}", "Phone")
    assert has_element?(view, "#device-last-seen-#{device.id}", "Nie")
    assert has_element?(view, "#device-revoke-#{device.id}", "Widerrufen")
  end

  test "a device revoked elsewhere leaves the list at once and is revoked once", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    device = device_fixture(scope)
    kept = device_fixture(scope, %{name: "Kept"})
    view = open_devices(conn)

    {:ok, _revoked} = Devices.revoke_device(scope, device, DateTime.utc_now(), reason: :sign_out)

    refute has_element?(view, "#device-#{device.id}")
    assert has_element?(view, "#device-#{kept.id}")

    html =
      view
      |> with_target("#devices-section")
      |> render_hook("revoke_device", %{"device_id" => to_string(device.id)})

    assert html =~ "That device was already signed out."
    refute html =~ "Device revoked."
    assert [_one] = revoked_events(user.id)
  end

  test "a device an org-admin revokes leaves the member's open list", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    organization_member_fixture(organization, user, :member)
    device = device_fixture(scope)
    view = open_devices(conn)

    {:ok, _} = admin |> user_scope_fixture() |> Devices.revoke_member_device(device.id)

    refute has_element?(view, "#device-#{device.id}")
    assert has_element?(view, "#device-list-empty")
  end

  test "a revoke while another section is open keeps the page up and shows on Devices", %{
    conn: conn,
    scope: scope
  } do
    device = device_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    {:ok, _} = Devices.revoke_device(scope, device)

    refute render(view) =~ "device-list"
    view |> element("#settings-tab-devices") |> render_click()
    assert has_element?(view, "#device-list-empty")
  end

  test "a crafted revoke of another person's device or a garbage id changes nothing", %{
    conn: conn,
    scope: scope
  } do
    device_fixture(scope)
    other = device_fixture(user_scope_fixture())
    view = open_devices(conn)

    target = with_target(view, "#devices-section")

    for id <- [Integer.to_string(other.id), other.id, "abc", "-1", 0] do
      assert render_hook(target, "revoke_device", %{"device_id" => id}) =~ "Device not found."
    end

    assert is_nil(Repo.get!(Device, other.id).revoked_at)

    # A payload with no id, or an id that is not a string or an integer, is
    # ignored.
    render_hook(target, "revoke_device", %{"device_id" => %{"id" => other.id}})
    render_hook(target, "revoke_device", %{})
    assert is_nil(Repo.get!(Device, other.id).revoked_at)
  end
end
