defmodule KanbanWeb.OrgLive.ConsoleMemberDevices do
  @moduledoc """
  A member's devices in the Members section of the org console
  (`KanbanWeb.OrgLive.Console`): opening and closing the list, revoking one
  device, and revoking them all.

  The console runs each of these inside
  `KanbanWeb.OrgLive.OrgAdminCheck.with_org_admin/2`, and the Devices context
  checks again on every call (`Kanban.Devices.MemberDevices`), so the ids in an
  event are only hints: a device or user outside the Organization is "Member
  not found.", an org-admin's devices are refused, and an actor who is no
  longer an org-admin is refused as the gate refuses.

  One member's devices are open at a time: `:devices_member_id` is that
  member's user id, or `nil`, and `:member_devices` their devices. After a
  revoke the list is read again, so it always shows what is still signed in.
  While it is open the console is subscribed to that member's device
  revocations (`Kanban.Devices.watch_member_devices/2`), so a device revoked
  on another page, by the member or another org-admin, leaves the list at
  once (`refresh/1`); closing the list unsubscribes.

  A member's Devices toggle shows only while they have a device that is not
  revoked: `:members_with_devices` is the set of those members' user ids, read
  with the members list in one query (`assign_members/1`), and kept up to date
  whenever a member's list is read. A list that comes back empty, after its
  last device is revoked, closes, and its toggle goes with it.

  Kept out of the console, which is at the module size guideline.
  """
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [refuse: 1]
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [clear_flash: 1, put_flash: 3, push_event: 3]

  alias Kanban.Devices
  alias Kanban.Organizations
  alias Phoenix.LiveView.Socket

  @doc """
  Reads the Organization's members into `:members`, and into
  `:members_with_devices` the user ids of its ordinary members with a device
  that is not revoked, from one devices query.
  """
  @spec assign_members(Socket.t()) :: Socket.t()
  def assign_members(%Socket{} = socket) do
    members = Organizations.list_members(socket.assigns.organization)
    ids = for %{role: :member, user: %{id: id}} <- members, do: id

    socket
    |> assign(:members, members)
    |> assign(
      :members_with_devices,
      Devices.users_with_active_devices(socket.assigns.current_scope, ids)
    )
  end

  @doc "Closes the open member's devices."
  @spec close(Socket.t()) :: Socket.t()
  def close(%Socket{} = socket) do
    case socket.assigns[:devices_member_id] do
      nil -> :ok
      member_id -> Devices.unwatch_member_devices(member_id)
    end

    socket
    |> assign(:devices_member_id, nil)
    |> assign(:member_devices, [])
  end

  @doc """
  Opens the devices of the member with `user_id`, or closes them when they are
  already open.
  """
  @spec toggle(Socket.t(), String.t() | integer()) :: {:noreply, Socket.t()}
  def toggle(%Socket{} = socket, user_id) do
    if to_string(user_id) == to_string(socket.assigns.devices_member_id) do
      {:noreply, close(socket)}
    else
      socket = close(socket)

      socket.assigns.current_scope
      |> Devices.watch_member_devices(user_id)
      |> respond_to_list(user_id, socket)
    end
  end

  @doc "Revokes one device of a member, then reads the open list again."
  @spec revoke_one(Socket.t(), String.t() | integer()) :: {:noreply, Socket.t()}
  def revoke_one(%Socket{} = socket, device_id) do
    socket.assigns.current_scope
    |> Devices.revoke_member_device(device_id)
    |> respond_to_revoke(fn _device -> gettext("Device revoked.") end, socket)
  end

  @doc "Revokes every device of the member with `user_id`, then reads the list again."
  @spec revoke_all(Socket.t(), String.t() | integer()) :: {:noreply, Socket.t()}
  def revoke_all(%Socket{} = socket, user_id) do
    socket.assigns.current_scope
    |> Devices.revoke_all_for_member(user_id)
    |> respond_to_revoke(&revoked_message/1, socket)
  end

  @doc """
  Reads the open member's devices again, after a revoke here or elsewhere. A
  list that can no longer be read (the member removed or promoted, or the
  actor no longer an org-admin) closes quietly, and the members list is read
  again: nothing was asked of it, and the next action is refused as usual.
  """
  @spec refresh(Socket.t()) :: {:noreply, Socket.t()}
  def refresh(%Socket{assigns: %{devices_member_id: nil}} = socket), do: {:noreply, socket}

  def refresh(%Socket{assigns: %{current_scope: scope, devices_member_id: member_id}} = socket) do
    case Devices.list_devices_for_member(scope, member_id) do
      {:ok, devices} ->
        {:noreply, show_devices(socket, member_id, devices)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> close()
         |> assign_members()}
    end
  end

  @doc """
  Closes the open member's devices when `:members` no longer lists that
  member as an ordinary member, after the members list is read again.
  """
  @spec close_if_gone(Socket.t()) :: Socket.t()
  def close_if_gone(%Socket{assigns: %{devices_member_id: nil}} = socket), do: socket

  def close_if_gone(%Socket{assigns: %{devices_member_id: id, members: members}} = socket) do
    if Enum.any?(members, &(&1.user.id == id and &1.role == :member)),
      do: socket,
      else: close(socket)
  end

  defp respond_to_list({:ok, devices}, user_id, socket),
    do: {:noreply, show_devices(socket, to_integer(user_id), devices)}

  defp respond_to_list({:error, reason}, _user_id, socket), do: refused(socket, reason)

  defp respond_to_revoke({:ok, revoked}, message, socket),
    do: report_and_reload(socket, message.(revoked))

  defp respond_to_revoke({:error, :already_revoked}, _message, socket),
    do: report_and_reload(socket, gettext("That device was already signed out."))

  defp respond_to_revoke({:error, reason}, _message, socket), do: refused(socket, reason)

  # The revoke's own outcome stands: a list that can no longer be read, of a
  # member removed or promoted meanwhile, closes without replacing it.
  defp report_and_reload(socket, message),
    do: socket |> replace_flash(:info, message) |> refresh()

  defp refused(socket, :unauthorized), do: {:noreply, refuse(socket)}

  defp refused(socket, :org_admin),
    do: {:noreply, closed(socket, gettext("An org-admin's devices can't be managed here."))}

  defp refused(socket, _not_found),
    do: {:noreply, closed(socket, gettext("Member not found."))}

  defp closed(socket, message) do
    socket
    |> replace_flash(:error, message)
    |> close()
    |> assign_members()
  end

  # A member with no device left has nothing to show or revoke: their list
  # closes and their toggle goes. Otherwise the list is open on their devices.
  defp show_devices(socket, member_id, []) do
    socket
    |> assign(:devices_member_id, member_id)
    |> close()
    |> update(:members_with_devices, &MapSet.delete(&1, member_id))
  end

  defp show_devices(socket, member_id, devices) do
    socket
    |> assign(:devices_member_id, member_id)
    |> assign(:member_devices, devices)
    |> update(:members_with_devices, &MapSet.put(&1, member_id))
  end

  defp revoked_message(revoked) do
    count = length(revoked)
    ngettext("%{count} device revoked.", "%{count} devices revoked.", count, count: count)
  end

  # The id the context accepted, as the integer the member rows compare to.
  defp to_integer(id) when is_integer(id), do: id
  defp to_integer(id) when is_binary(id), do: String.to_integer(id)

  # As the console's own: every message replaces the one before it, and
  # "flash:shown" restarts the info message's dismiss timer.
  defp replace_flash(socket, kind, message) do
    socket
    |> clear_flash()
    |> put_flash(kind, message)
    |> push_event("flash:shown", %{kind: Atom.to_string(kind)})
  end
end
