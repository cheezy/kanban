defmodule KanbanWeb.OrgLive.AuditStreamForm do
  @moduledoc """
  The org-admin form that adds an audit stream destination at
  `/org/audit/streaming/new` and changes one at
  `/org/audit/streaming/:id/edit` (W2717, `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`
  §5.1 to §5.3, §8.5, §10.3, §10.5, §12.3, §12.5): a Splunk HTTP Event
  Collector, a Datadog logs intake or an HTTPS endpoint.

  As on the list page, `current_scope` goes stale, so every event re-reads
  the actor and their org-admin role first (`KanbanWeb.OrgLive.OrgAdminCheck`)
  and hands `Kanban.AuditStream` a scope built from that fresh actor; the
  context checks once more, validates, checks the URL with UrlGuard and
  saves. A refused event is audited as `permission_denied` and redirects to
  `/boards`. An edit fetches the destination again inside the actor's own
  Organization by the id loaded from the route, never one from the form.

  Secrets are write-only (§12.2). The socket never holds a changeset or a
  `%Destination{}`: only the destination's id, `lock_version`,
  `filter_version`, its secret hints and states, and the plain values
  `KanbanWeb.OrgLive.AuditStreamFormView` builds, which carry no URL or
  credential. A secret input is always rendered empty, and a blank one keeps
  the stored value. The signing secret of a new HTTPS destination is held
  once, in the `:new_secret` assign, until the next event or **Dismiss**.

  Every save sends a test event in `start_async/3`: the destination is saved
  even when the test fails, and only the coarse result is shown (§12.5).
  """
  use KanbanWeb, :live_view

  import KanbanWeb.OrgLive.OrgAdminCheck, only: [with_org_admin: 3, refuse: 2]
  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Destination
  alias KanbanWeb.OrgLive.AuditStreamFormView
  alias KanbanWeb.OrgLive.AuditStreamingRow
  alias KanbanWeb.OrgLive.AuditStreamKinds

  require Logger

  defmodule ShownSecret do
    @moduledoc """
    The signing secret shown once after an HTTPS destination's first save.
    It is never inspected, so a crash report that prints the LiveView's
    state, as one at the `:debug` level does, never holds it (§12.2).
    """
    @derive {Inspect, only: []}
    @enforce_keys [:value]
    defstruct [:value]
  end

  on_mount {KanbanWeb.UserAuth, :require_org_admin}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:organization, socket.assigns.current_organization)
      |> assign(shown_for: nil, test_result: nil, testing: false)
      |> clear_transient()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> forget_other_destination(params["id"])
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  # The signing secret and the test result belong to one destination, so a
  # patch to /new or to another destination's edit page drops them and stops
  # a test event still running. The patch that follows a create keeps them.
  defp forget_other_destination(%{assigns: %{shown_for: id}} = socket, target)
       when not is_nil(id) and is_binary(target) do
    if Integer.to_string(id) == target, do: socket, else: forget_shown(socket)
  end

  defp forget_other_destination(socket, _target), do: forget_shown(socket)

  defp forget_shown(socket) do
    socket
    |> cancel_async(:test_event)
    |> assign(shown_for: nil, test_result: nil, testing: false)
    |> clear_transient()
  end

  defp apply_action(socket, :new, _params) do
    scope = Scope.for_user(socket.assigns.current_scope.user)

    case AuditStream.list_destinations(scope) do
      {:ok, destinations} ->
        if length(destinations) >= Destination.max_destinations(),
          do: limit_reached(socket),
          else: new_form(socket, scope)

      {:error, :unauthorized} ->
        refuse(socket, refuse_opts())
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = Scope.for_user(socket.assigns.current_scope.user)

    case AuditStream.get_destination(scope, id) do
      {:ok, destination} -> edit_form(socket, scope, destination)
      {:error, :unauthorized} -> refuse(socket, refuse_opts())
      {:error, :not_found} -> gone(socket, gettext("Destination not found."))
    end
  end

  defp new_form(socket, scope) do
    changeset = AuditStream.change_destination(scope, %Destination{}, %{"kind" => "splunk_hec"})

    socket
    |> assign(page_title: gettext("Add destination"), kind: :splunk_hec, start_from: "now")
    |> assign(destination_id: nil, lock_version: nil, filter_version: nil, stored_filters: nil)
    |> assign(hints: %{}, secret_states: %{url: :empty, credential: :empty})
    |> assign(batch_pending: false, replacing: MapSet.new())
    |> assign_form(changeset, %{}, false)
  end

  defp edit_form(socket, scope, %Destination{} = destination) do
    socket
    |> assign(:page_title, gettext("Edit destination"))
    |> assign_destination(scope, destination)
    |> assign_form(AuditStream.change_destination(scope, destination, %{}), %{}, false)
  end

  # Only what the form needs of the saved destination: never its secrets.
  defp assign_destination(socket, scope, %Destination{} = destination) do
    socket
    |> assign(destination_id: destination.id, lock_version: destination.lock_version)
    |> assign(filter_version: destination.filter_version, kind: destination.kind)
    |> assign(:stored_filters, AuditStreamFormView.filters(destination))
    |> assign(
      hints: AuditStreamFormView.hints(destination),
      secret_states: AuditStreamFormView.secret_states(destination)
    )
    |> assign(:batch_pending, AuditStream.batch_pending(scope, destination) == {:ok, true})
    |> assign(:replacing, MapSet.new())
    |> assign(:start_from, nil)
  end

  @impl true
  def handle_event("validate", %{"destination" => params}, socket) when is_map(params) do
    contained(socket, "validate", fn ->
      params = AuditStreamFormView.lift_secrets(params)
      act(socket, &{:noreply, validate(&2, &1, params)})
    end)
  end

  def handle_event("save", %{"destination" => params}, socket) when is_map(params) do
    contained(socket, "save", fn ->
      params = AuditStreamFormView.lift_secrets(params)
      act(socket, &{:noreply, save(&2, &1, params)})
    end)
  end

  def handle_event("replace_secret", %{"field" => field}, socket)
      when field in ["url", "credential"] do
    field = if field == "url", do: :url, else: :credential

    act(socket, fn _scope, socket ->
      {:noreply, update(socket, :replacing, &MapSet.put(&1, field))}
    end)
  end

  def handle_event("dismiss_secret", _params, socket),
    do: act(socket, fn _scope, socket -> {:noreply, socket} end)

  def handle_event(_event, _params, socket), do: {:noreply, clear_transient(socket)}

  # Re-check the actor, then run `fun` with a scope built from them. Every
  # event clears a signing secret still shown and the re-send note.
  # A raise, exit or throw in validate or save would crash the LiveView, and
  # the crash report logs the last message, whose form payload holds the
  # typed URL and credential (§12.2). So it is contained here: only the
  # exception's module (or the kind of failure) is logged and reported to
  # ErrorTracker, never its message or reason, which can quote the values
  # involved. A signing secret still shown is cleared, as by any event.
  defp contained(socket, event, fun) do
    fun.()
  catch
    kind, reason ->
      failure = "Audit stream form #{event} failed: #{failure_name(kind, reason, __STACKTRACE__)}"
      Logger.error(failure)
      report(failure, __STACKTRACE__)

      {:noreply,
       socket
       |> clear_transient()
       |> put_flash(:error, gettext("Something went wrong. Please try again."))}
  end

  defp failure_name(:error, reason, stacktrace),
    do: inspect(Exception.normalize(:error, reason, stacktrace).__struct__)

  defp failure_name(kind, _reason, _stacktrace), do: inspect(kind)

  # Reporting must not crash the view either (the store can be down), or the
  # payload would reach the crash report after all.
  defp report(failure, stacktrace) do
    ErrorTracker.report(%RuntimeError{message: failure}, stacktrace)
  catch
    _kind, _reason -> :ok
  end

  defp act(socket, fun) do
    with_org_admin(
      socket,
      fn actor -> actor |> Scope.for_user() |> fun.(clear_transient(socket)) end,
      refuse_opts()
    )
  end

  defp validate(%{assigns: %{live_action: :new}} = socket, scope, params) do
    kind = AuditStreamKinds.parse_kind(params["kind"]) || socket.assigns.kind
    start_from = AuditStreamKinds.normalize_start(kind, params["start_from"])

    changeset =
      scope
      |> AuditStream.change_destination(
        %Destination{},
        AuditStreamFormView.attrs(params, :new, kind)
      )
      |> Map.put(:action, :validate)

    socket
    |> assign(kind: kind, start_from: start_from)
    |> assign_form(changeset, params, false)
  end

  defp validate(socket, scope, params) do
    case AuditStream.get_destination(scope, socket.assigns.destination_id) do
      {:ok, destination} ->
        changeset =
          scope
          |> AuditStream.change_destination(destination, edit_attrs(socket, params))
          |> Map.put(:action, :validate)

        assign_form(socket, changeset, params, false)

      {:error, :unauthorized} ->
        refuse(socket, refuse_opts())

      {:error, :not_found} ->
        gone(socket, gettext("That destination no longer exists."))
    end
  end

  defp save(%{assigns: %{live_action: :new}} = socket, scope, params) do
    kind = AuditStreamKinds.parse_kind(params["kind"]) || socket.assigns.kind

    scope
    |> AuditStream.create_destination(AuditStreamFormView.attrs(params, :new, kind))
    |> created(socket, scope, kind, params)
  end

  defp save(socket, scope, params) do
    stub = %Destination{
      id: socket.assigns.destination_id,
      lock_version: socket.assigns.lock_version
    }

    case AuditStream.update_destination(scope, stub, edit_attrs(socket, params)) do
      {:ok, %Destination{}} ->
        saved(socket, scope)

      {:error, %Changeset{} = changeset} ->
        socket
        |> stale_flash(changeset)
        |> assign_form(changeset, params, true)

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp created({:ok, {%Destination{id: id}, secret}}, socket, scope, _kind, _params) do
    socket
    |> assign(:new_secret, secret && %ShownSecret{value: secret})
    |> put_flash(:info, gettext("Destination saved."))
    |> run_test(scope, id)
    |> push_patch(to: ~p"/org/audit/streaming/#{id}/edit")
  end

  defp created({:error, :limit_reached}, socket, _scope, _kind, _params),
    do: limit_reached(socket)

  defp created({:error, %Changeset{} = changeset}, socket, _scope, kind, params) do
    socket
    |> assign(
      kind: kind,
      start_from: AuditStreamKinds.normalize_start(kind, params["start_from"])
    )
    |> assign_form(changeset, params, true)
  end

  defp created({:error, reason}, socket, _scope, _kind, _params), do: refused(socket, reason)

  # The saved destination is read again, so the form shows what is stored.
  defp saved(socket, scope) do
    case AuditStream.get_destination(scope, socket.assigns.destination_id) do
      {:ok, destination} -> reload_saved(socket, scope, destination)
      {:error, reason} -> refused(socket, reason)
    end
  end

  defp reload_saved(socket, scope, destination) do
    resent? = resent?(socket, scope, destination)
    changeset = AuditStream.change_destination(scope, destination, %{})

    socket
    |> assign_destination(scope, destination)
    |> assign(:resent, resent?)
    |> assign_form(changeset, %{}, false)
    |> put_flash(:info, gettext("Destination saved."))
    |> run_test(scope, destination.id)
  end

  # The filters changed with this save while a batch waited (D16).
  defp resent?(socket, scope, destination) do
    destination.filter_version > socket.assigns.filter_version and
      AuditStream.batch_pending(scope, destination) == {:ok, true}
  end

  defp edit_attrs(socket, params),
    do: AuditStreamFormView.attrs(params, :edit, socket.assigns.kind)

  defp stale_flash(socket, changeset) do
    if AuditStreamFormView.stale?(changeset) do
      put_flash(
        socket,
        :error,
        gettext(
          "This destination changed since you opened it. Reload the page to see the changes, then save again."
        )
      )
    else
      socket
    end
  end

  defp refused(socket, :unauthorized), do: refuse(socket, refuse_opts())

  defp refused(socket, _not_found),
    do: gone(socket, gettext("That destination no longer exists."))

  defp run_test(socket, scope, id) do
    socket
    |> assign(shown_for: id, testing: true, test_result: nil)
    |> start_async(:test_event, fn ->
      AuditStream.send_test_event(scope, %Destination{id: id})
    end)
  end

  @impl true
  def handle_async(:test_event, {:ok, {:error, :unauthorized}}, socket),
    do: {:noreply, socket |> assign(:testing, false) |> refuse(refuse_opts())}

  def handle_async(:test_event, {:ok, result}, socket),
    do:
      {:noreply,
       assign(socket, testing: false, test_result: AuditStreamingRow.test_result(result))}

  # A test event cancelled by a patch to another destination: that page
  # shows no result for it.
  def handle_async(:test_event, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:test_event, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, testing: false, test_result: AuditStreamingRow.test_result(:exit))}

  defp assign_form(socket, %Changeset{} = changeset, params, submitted?) do
    values = AuditStreamFormView.values(changeset, params)

    socket
    |> assign(:values, values)
    |> assign(:errors, AuditStreamFormView.errors(changeset, params, submitted?))
    |> assign(:url_warning, AuditStreamKinds.url_warning(socket.assigns.kind, params["url"]))
    |> assign(:form, to_form(%{}, as: :destination))
  end

  defp limit_reached(socket) do
    max = Destination.max_destinations()

    socket
    |> put_flash(
      :error,
      ngettext(
        "This Organization already has %{count} destination, the most it can have.",
        "This Organization already has %{count} destinations, the most it can have.",
        max
      )
    )
    |> push_navigate(to: ~p"/org/audit/streaming")
  end

  defp gone(socket, message),
    do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/org/audit/streaming")

  defp refuse_opts, do: [on_refuse: &clear_transient/1]

  defp clear_transient(socket), do: assign(socket, new_secret: nil, resent: false)

  @doc false
  # The re-send note: after a save that changed the filters while a batch
  # waited, or while the form's filters differ from the stored ones.
  def resend_note?(assigns) do
    assigns.resent or
      (assigns.batch_pending and
         AuditStreamFormView.filters_changed?(assigns.values, assigns.stored_filters))
  end

  @doc false
  # The colour token of the test result line.
  def result_token(true, _result), do: "ink-2"
  def result_token(false, {:ok, _text}), do: "st-done"
  def result_token(false, _result), do: "st-blocked"

  @doc false
  # A secret input is shown when there is nothing stored, the stored one
  # can't be read, or Replace was pressed; else its hint is.
  def secret_input?(assigns, field),
    do:
      assigns.secret_states[field] in [:empty, :unreadable] or
        MapSet.member?(assigns.replacing, field)
end
