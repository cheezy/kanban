defmodule KanbanWeb.OrgLive.AuditStreamDestination do
  @moduledoc """
  The org-admin page of one audit stream destination at
  `/org/audit/streaming/:id` (W2718, `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`
  §8.4, §8.6, §8.7, §10.4, §15 D3): its non-secret settings, its status in
  full with the halted reason in words, the lag, its open and dismissed gaps
  with **Dismiss**, the last 50 attempts, **Rotate signing secret** for an
  HTTPS endpoint, and for a rejected batch the two ways out, **Retry now** and
  **Skip this batch**. Stride never skips a batch on its own (D3), so this
  page is where a person decides.

  The destination is always loaded through `Kanban.AuditStream`, scoped to
  the actor's own Organization, so another Organization's id, a missing id or
  one that is not a number redirects to the list as not found. As on the list
  page, `current_scope` goes stale, so every event re-reads the actor and
  their org-admin role first (`KanbanWeb.OrgLive.OrgAdminCheck`), fetches the
  destination again by the id loaded at mount (never one from params), and
  hands the context a scope built from that fresh actor; the context checks
  once more, takes the destination's lease for a skip or retry, and records
  the audit events. A refused event is audited as `permission_denied` and
  redirects to `/boards`.

  The socket holds only the map `KanbanWeb.OrgLive.AuditStreamDestinationView`
  builds, with no URL, credential or signing secret (§12.2). A rotated
  signing secret is held once, in the `:new_secret` assign, until the next
  event or **Dismiss**; it is never logged, flashed or put in audit metadata.
  Attempt errors are Stride's own classification, at most 200 characters,
  never a response body, and are rendered escaped (§8.7).
  """
  use KanbanWeb, :live_view

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 3, refuse: 2]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Destination
  alias KanbanWeb.OrgLive.AuditStreamDestinationView
  alias KanbanWeb.OrgLive.AuditStreamingRow

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Audit stream destination"))
      |> assign(:organization, socket.assigns.current_organization)
      |> clear_secret()

    {:ok, load(socket, socket.assigns.current_scope.user, id)}
  end

  @impl true
  def handle_event("dismiss_secret", _params, socket), do: {:noreply, clear_secret(socket)}

  def handle_event("dismiss_gap", %{"id" => gap_id}, socket) when is_binary(gap_id) do
    act(
      socket,
      fn scope, destination ->
        with {:ok, gaps} <- AuditStream.list_gaps(scope, destination) do
          case Enum.find(gaps, &(to_string(&1.id) == to_string(gap_id))) do
            nil -> {:ok, nil}
            gap -> AuditStream.dismiss_gap(scope, gap)
          end
        end
      end,
      gettext("Gap dismissed.")
    )
  end

  def handle_event("rotate_secret", _params, socket),
    do: act(socket, &AuditStream.rotate_signing_secret/2, gettext("Signing secret rotated."))

  def handle_event("retry_now", _params, socket),
    do: act(socket, &AuditStream.retry_now/2, gettext("Retrying the batch now."))

  def handle_event("skip_batch", _params, socket),
    do: act(socket, &AuditStream.skip_batch/2, gettext("Batch skipped."))

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Re-check the actor, fetch the destination again inside their
  # Organization by the id loaded at mount, then call the context with a
  # scope built from that fresh actor. Any event but a rotation clears a
  # secret still shown.
  defp act(socket, fun, done) do
    with_org_admin(
      socket,
      fn actor ->
        scope = Scope.for_user(actor)

        result =
          with {:ok, destination} <- AuditStream.get_destination(scope, socket.assigns.view.id),
               do: fun.(scope, destination)

        respond(result, clear_secret(socket), actor, done)
      end,
      refuse_opts()
    )
  end

  defp respond({:ok, {%Destination{} = destination, secret}}, socket, actor, done)
       when is_binary(secret) do
    {:noreply,
     socket
     |> assign(:new_secret, secret)
     |> assign(:new_secret_valid_until, destination.previous_secret_expires_at)
     |> reload(actor)
     |> put_flash(:info, done)}
  end

  # A gap that is not this destination's changes nothing.
  defp respond({:ok, nil}, socket, actor, _done), do: {:noreply, reload(socket, actor)}

  defp respond({:ok, _changed}, socket, actor, done),
    do: {:noreply, socket |> reload(actor) |> put_flash(:info, done)}

  defp respond({:error, :not_found}, socket, _actor, _done) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("That destination no longer exists."))
     |> push_navigate(to: ~p"/org/audit/streaming")}
  end

  defp respond({:error, :unauthorized}, socket, _actor, _done),
    do: {:noreply, refuse(socket, refuse_opts())}

  defp respond({:error, reason}, socket, actor, _done),
    do: {:noreply, socket |> reload(actor) |> put_flash(:error, error_text(reason))}

  defp error_text(:not_rejected_batch),
    do: gettext("This destination is no longer waiting on a rejected batch.")

  defp error_text(:busy),
    do: gettext("A delivery is running for this destination. Try again in a minute.")

  defp error_text(:not_https), do: gettext("Only HTTPS endpoints have a signing secret.")

  defp error_text({:rotation_overlap, %DateTime{} = at}),
    do:
      gettext("You can rotate the signing secret again after %{time} UTC.",
        time: AuditStreamDestinationView.utc(at)
      )

  defp error_text(_changed),
    do: gettext("This destination changed since the page loaded. Try again.")

  defp refuse_opts, do: [on_refuse: &clear_secret/1]

  defp clear_secret(socket),
    do: socket |> assign(:new_secret, nil) |> assign(:new_secret_valid_until, nil)

  defp reload(socket, actor), do: load(socket, actor, socket.assigns.view.id)

  defp load(socket, %User{} = actor, id) do
    scope = Scope.for_user(actor)

    case fetch_page(scope, id) do
      {:ok, page} ->
        assign_page(socket, page)

      {:error, :unauthorized} ->
        refuse(socket, refuse_opts())

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("Destination not found."))
        |> push_navigate(to: ~p"/org/audit/streaming")
    end
  end

  defp fetch_page(scope, id) do
    with {:ok, destination} <- AuditStream.get_destination(scope, id),
         {:ok, status} <- AuditStream.destination_status(scope, destination),
         {:ok, history} <- fetch_history(scope, destination) do
      {:ok, Map.merge(history, %{destination: destination, status: status})}
    end
  end

  defp fetch_history(scope, destination) do
    with {:ok, attempts} <- AuditStream.list_attempts(scope, destination),
         {:ok, gaps} <- AuditStream.list_gaps(scope, destination),
         {:ok, batch} <- AuditStream.pending_batch_summary(scope, destination) do
      {:ok, %{attempts: attempts, gaps: gaps, batch: batch}}
    end
  end

  defp assign_page(socket, %{destination: destination, status: status} = page) do
    view = AuditStreamDestinationView.to_view(destination)

    socket
    |> assign(Map.take(page, [:status, :attempts, :gaps, :batch]))
    |> assign(page_title: destination.name, view: view)
    |> assign(:actions, AuditStreamDestinationView.actions(status, page.batch))
    |> assign(:config_error_fix, config_error_fix(view, page))
  end

  defp config_error_fix(view, %{status: status, attempts: attempts}),
    do: AuditStreamDestinationView.config_error_fix(view, status, attempts)

  @doc false
  # The state line under the pill: the halt in words, else the stored
  # reason while Retrying or Failing (a paused destination's is stale).
  def reason(%{halted_reason: halted} = status) when not is_nil(halted),
    do: AuditStreamDestinationView.halted_text(halted) || status.state_reason

  def reason(%{state: state}) when state in [:paused, :healthy], do: nil
  def reason(%{state_reason: reason}), do: reason

  defdelegate state_label(state), to: AuditStreamingRow
  defdelegate state_token(state), to: AuditStreamingRow
end
