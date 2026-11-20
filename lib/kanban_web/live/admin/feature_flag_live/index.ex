defmodule KanbanWeb.Admin.FeatureFlagLive.Index do
  @moduledoc """
  `/admin/feature-flags`: a site admin turns each registered flag on for
  chosen users, by email, or for everyone. Every change goes through
  `Kanban.FeatureFlags`, which audits it and broadcasts it, so every open copy
  of this page refreshes. `docs/feature-flags.md` describes the page.
  """
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares
  # `{KanbanWeb.UserAuth, :require_admin}` for this route, but we re-declare it
  # here so the LiveView itself cannot be reached by a non-admin even if the
  # route is ever re-grouped or the on_mount hook is dropped from the
  # live_session declaration.
  on_mount {KanbanWeb.UserAuth, :require_admin}

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.FeatureFlags

  @max_bigint 9_223_372_036_854_775_807

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: FeatureFlags.subscribe()

    {:ok,
     socket
     |> assign(:page_title, gettext("Feature flags"))
     |> assign(:confirming, nil)
     |> assign(:forms, Map.new(FeatureFlags.flags(), &{&1, email_form(&1, "")}))
     |> refresh()}
  end

  @impl true
  def handle_event("add_user", %{"flag" => flag} = params, socket) do
    email = submitted_email(params)

    with_flag(socket, flag, &add_user(socket, &1, &2, email))
  end

  def handle_event("remove_user", %{"flag" => flag, "id" => id}, socket) do
    with_flag(socket, flag, fn flag, scope ->
      case parse_id(id) do
        nil ->
          respond(socket, :error, gettext("That user no longer has this flag."))

        user_id ->
          scope
          |> FeatureFlags.turn_off_for_user_id(flag, user_id)
          |> respond_result(socket, gettext("Turned off for that user."), :user)
      end
    end)
  end

  def handle_event("confirm_everyone", %{"flag" => flag, "to" => to}, socket) do
    with_flag(socket, flag, fn flag, _scope ->
      case parse_to(to) do
        nil -> {:noreply, socket}
        to -> {:noreply, assign(socket, :confirming, {flag, to})}
      end
    end)
  end

  def handle_event("cancel_everyone", _params, socket),
    do: {:noreply, assign(socket, :confirming, nil)}

  # The confirm is enforced here, not in the browser: a pushed set_everyone
  # with no matching confirm_everyone before it changes nothing.
  def handle_event("set_everyone", %{"flag" => flag, "to" => to}, socket) do
    with_flag(socket, flag, fn flag, scope ->
      to = parse_to(to)

      if to != nil and socket.assigns.confirming == {flag, to} do
        socket
        |> assign(:confirming, nil)
        |> set_everyone(scope, flag, to)
      else
        respond(socket, :error, gettext("Confirm the change first."))
      end
    end)
  end

  # A hand-crafted push with missing or malformed params changes nothing and
  # never crashes the view, whose crash report would log the event payload.
  # It only flashes: it reads nothing, so it needs no admin check.
  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Unknown feature flag."))}

  # Another admin, or this page in another tab, changed a flag. An admin who
  # has since been demoted or disabled is sent away rather than shown it.
  @impl true
  def handle_info({:feature_flag_changed, _flag}, socket) do
    case authorized_actor(socket) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You must be an admin to perform this action."))
         |> push_navigate(to: ~p"/")}

      _actor ->
        {:noreply, socket |> refresh() |> drop_stale_confirm()}
    end
  end

  defp add_user(socket, flag, scope, email) do
    case FeatureFlags.turn_on_for_email(scope, flag, email) do
      :ok ->
        socket
        |> update(:forms, &Map.put(&1, flag, email_form(flag, "")))
        |> respond(:info, gettext("Turned on for that user."))

      {:error, reason} ->
        socket
        |> update(:forms, &Map.put(&1, flag, email_form(flag, email)))
        |> respond_error(reason, :user)
    end
  end

  defp set_everyone(socket, scope, flag, :on) do
    scope
    |> FeatureFlags.turn_on_for_everyone(flag)
    |> respond_result(socket, gettext("Turned on for everyone."), :everyone)
  end

  defp set_everyone(socket, scope, flag, :off) do
    scope
    |> FeatureFlags.turn_off_for_everyone(flag)
    |> respond_result(socket, gettext("Turned off for everyone."), :everyone)
  end

  # Every event re-reads the actor from the database and resolves the flag
  # against the registry, so a demoted admin or a forged flag name changes
  # nothing.
  defp with_flag(socket, flag_param, fun) do
    case {authorized_actor(socket), parse_flag(flag_param)} do
      {nil, _flag} -> halt_non_admin(socket)
      {_actor, nil} -> respond(socket, :error, gettext("Unknown feature flag."))
      {actor, flag} -> fun.(flag, Scope.for_user(actor))
    end
  end

  defp respond_result(:ok, socket, message, _target), do: respond(socket, :info, message)

  defp respond_result({:error, reason}, socket, _message, target),
    do: respond_error(socket, reason, target)

  # A refused change only flashes and keeps the overviews already shown: it
  # changed nothing, and reading the store again could raise inside an event
  # whose crash report would carry the typed address. Every change that did
  # happen is broadcast, which refreshes the page.
  defp respond_error(socket, :already_enabled, target),
    do: {:noreply, put_flash(socket, :info, already_message(target))}

  defp respond_error(socket, reason, target),
    do: {:noreply, put_flash(socket, :error, error_message(reason, target))}

  defp respond(socket, kind, message),
    do: {:noreply, socket |> put_flash(kind, message) |> refresh()}

  defp refresh(socket),
    do: assign(socket, :overviews, Enum.map(FeatureFlags.flags(), &FeatureFlags.overview/1))

  # A confirm that no longer applies (another admin already made the change)
  # is dropped rather than left offering a no-op.
  defp drop_stale_confirm(%{assigns: %{confirming: {flag, to}}} = socket) do
    everyone? = Enum.find(socket.assigns.overviews, &(&1.flag == flag)).everyone?

    if (to == :on and everyone?) or (to == :off and not everyone?),
      do: assign(socket, :confirming, nil),
      else: socket
  end

  defp drop_stale_confirm(socket), do: socket

  defp email_form(flag, email),
    do: to_form(%{"email" => email}, as: :add_user, id: "add-user-#{flag}")

  defp already_message(:user), do: gettext("That user already has this flag.")
  defp already_message(:everyone), do: gettext("This flag is already on for everyone.")

  defp error_message(:unauthorized, _target),
    do: gettext("You must be an admin to perform this action.")

  defp error_message(:invalid_email, _target), do: gettext("Enter an email address.")
  defp error_message(:user_not_found, _target), do: gettext("No account uses that email address.")

  defp error_message(:user_disabled, _target),
    do: gettext("That account is disabled, so it was not added.")

  defp error_message(:not_enabled, :user), do: gettext("That user no longer has this flag.")

  defp error_message(:not_enabled, :everyone),
    do: gettext("This flag is already off for everyone.")

  defp error_message(_reason, _target),
    do: gettext("The change could not be saved. Please try again.")

  # current_scope is loaded at mount and never refreshed, so it still claims
  # admin for someone since disabled or demoted. Re-read the actor on every
  # event and broadcast, as KanbanWeb.Admin.UserLive.Index does.
  defp authorized_actor(socket) do
    with %{user: %{id: id}} <- socket.assigns[:current_scope],
         %User{type: :admin, disabled_at: nil} = actor <- Accounts.get_user(id) do
      actor
    else
      _ -> nil
    end
  end

  defp halt_non_admin(socket) do
    {:noreply, put_flash(socket, :error, gettext("You must be an admin to perform this action."))}
  end

  defp submitted_email(%{"add_user" => %{"email" => email}}) when is_binary(email), do: email
  defp submitted_email(_params), do: ""

  # Matched against the compiled registry, never String.to_atom/1.
  defp parse_flag(param) when is_binary(param),
    do: Enum.find(FeatureFlags.flags(), &(Atom.to_string(&1) == param))

  defp parse_flag(_param), do: nil

  defp parse_to("on"), do: :on
  defp parse_to("off"), do: :off
  defp parse_to(_to), do: nil

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 and int <= @max_bigint -> int
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp flag_label(:mobile_app_preview), do: gettext("Mobile app preview")

  defp flag_description(:mobile_app_preview),
    do:
      gettext(
        "Shows the screens that matter only once the phone apps ship: the device list in account settings, the push notification settings, and the Organization policy that hides task titles in pushes."
      )

  defp state_label(%{everyone?: true}), do: gettext("On for everyone")
  defp state_label(%{users: [], missing_user_ids: []}), do: gettext("Off")

  defp state_label(%{users: users, missing_user_ids: missing}) do
    count = length(users) + length(missing)
    ngettext("On for %{count} user", "On for %{count} users", count)
  end

  defp state_class(%{everyone?: true}), do: "badge-success"
  defp state_class(%{users: [], missing_user_ids: []}), do: "badge-ghost"
  defp state_class(_overview), do: "badge-primary"

  defp gated?(%{users: users, missing_user_ids: missing}), do: users != [] or missing != []

  defp confirm_text(flag, :on),
    do:
      gettext(
        "Turn %{flag} on for everyone? Every user, and every visitor who is not signed in, gets it at once.",
        flag: flag_label(flag)
      )

  defp confirm_text(flag, :off),
    do:
      gettext("Turn %{flag} off for everyone? Users with their own gate keep it.",
        flag: flag_label(flag)
      )

  defp confirm_to({flag, to}, flag), do: to
  defp confirm_to(_confirming, _flag), do: nil

  defp confirm_button_label(:on), do: gettext("Turn on for everyone")
  defp confirm_button_label(:off), do: gettext("Turn off for everyone")

  defp disabled?(%User{disabled_at: nil}), do: false
  defp disabled?(%User{}), do: true
end
