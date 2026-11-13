defmodule KanbanWeb.OrgLive.AuditStreaming do
  @moduledoc """
  The org-admin Audit streaming page at `/org/audit/streaming` (W2716,
  `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §10.1, §10.2, §10.5): every
  audit stream destination of the Organization with its status, when it last
  delivered and how far behind it is, and **Pause**/**Resume**, **Send test
  event** and **Delete**.

  The Organization comes from `current_organization`, which the
  `:require_org_admin` gate assigns from the signed-in user's own membership;
  it is never read from params. `current_scope` is loaded once at mount and
  goes stale, so every event re-reads the actor and their org-admin role
  first (`KanbanWeb.OrgLive.OrgAdminCheck`) and hands `Kanban.AuditStream` a
  scope built from that fresh actor; the context checks once more. A refused
  event is audited as `permission_denied` and redirects to `/boards`. The
  destination an event names is fetched again by id inside the actor's own
  Organization, so an id from another Organization, or of a destination
  deleted since the page loaded, changes nothing and reloads the list.

  The socket holds only the rows `KanbanWeb.OrgLive.AuditStreamingRow`
  builds, which carry no URL, credential or signing secret (§12.2). A test
  event runs in `start_async/3`, so the page stays responsive while it waits
  for the destination, and shows only the coarse result (§10.3, §12.5).
  """
  use KanbanWeb, :live_view

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 2, refuse: 1]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations
  alias KanbanWeb.OrgLive.AuditStreamingRow

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Audit streaming"))
      |> assign(:organization, socket.assigns.current_organization)
      |> assign(:max_destinations, Destination.max_destinations())
      |> assign(:test_results, %{})
      |> assign(:testing, MapSet.new())

    {:ok, load(socket, socket.assigns.current_scope.user)}
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket),
    do: act(socket, id, &AuditStream.pause_destination/2, gettext("Destination paused."))

  def handle_event("resume", %{"id" => id}, socket),
    do: act(socket, id, &AuditStream.resume_destination/2, gettext("Destination resumed."))

  def handle_event("delete", %{"id" => id}, socket),
    do: act(socket, id, &AuditStream.delete_destination/2, gettext("Destination deleted."))

  def handle_event("send_test", %{"id" => id}, socket) do
    with_org_admin(socket, fn actor ->
      scope = Scope.for_user(actor)

      case AuditStream.get_destination(scope, id) do
        {:ok, destination} -> {:noreply, start_test(socket, scope, destination)}
        {:error, reason} -> respond({:error, reason}, socket, actor, nil)
      end
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:test_event, id}, {:ok, result}, socket),
    do: {:noreply, put_test_result(socket, id, result)}

  def handle_async({:test_event, id}, {:exit, _reason}, socket),
    do: {:noreply, put_test_result(socket, id, :exit)}

  # Pause, resume and delete: re-check the actor, fetch the destination again
  # inside their Organization, then call the context with a scope built from
  # that fresh actor.
  defp act(socket, id, fun, done) do
    with_org_admin(socket, fn actor ->
      scope = Scope.for_user(actor)

      result =
        with {:ok, destination} <- AuditStream.get_destination(scope, id),
             do: fun.(scope, destination)

      respond(result, socket, actor, done)
    end)
  end

  defp respond({:ok, _destination}, socket, actor, done),
    do: {:noreply, socket |> load(actor) |> put_flash(:info, done)}

  defp respond({:error, :not_found}, socket, actor, _done) do
    {:noreply,
     socket
     |> load(actor)
     |> put_flash(:error, gettext("That destination no longer exists."))}
  end

  defp respond({:error, :unauthorized}, socket, _actor, _done), do: {:noreply, refuse(socket)}

  # A test already in flight for this destination is left to finish: a second
  # click would send, audit and count against the hourly limit again while only
  # its own result could ever be shown.
  defp start_test(socket, scope, %Destination{id: id} = destination) do
    if MapSet.member?(socket.assigns.testing, id),
      do: socket,
      else: run_test(socket, scope, destination)
  end

  defp run_test(socket, scope, %Destination{id: id} = destination) do
    socket
    |> update(:testing, &MapSet.put(&1, id))
    |> update(:test_results, &Map.delete(&1, id))
    |> start_async({:test_event, id}, fn -> AuditStream.send_test_event(scope, destination) end)
  end

  defp put_test_result(socket, id, {:error, :unauthorized}),
    do: socket |> update(:testing, &MapSet.delete(&1, id)) |> refuse()

  defp put_test_result(socket, id, result) do
    socket
    |> update(:testing, &MapSet.delete(&1, id))
    |> update(:test_results, &Map.put(&1, id, AuditStreamingRow.test_result(result)))
  end

  defp load(socket, %User{} = actor) do
    case actor |> Scope.for_user() |> AuditStream.list_destinations_with_status() do
      {:ok, entries} ->
        socket
        |> assign(:rows, Enum.map(entries, &AuditStreamingRow.to_view/1))
        |> assign(
          :org_admin_count,
          Organizations.count_enabled_org_admins(socket.assigns.organization)
        )

      {:error, :unauthorized} ->
        socket |> assign(:rows, []) |> assign(:org_admin_count, 0) |> refuse()
    end
  end
end
