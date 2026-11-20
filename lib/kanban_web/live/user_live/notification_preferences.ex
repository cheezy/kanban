defmodule KanbanWeb.UserLive.NotificationPreferences do
  @moduledoc """
  Per-event notification preferences at `/users/notifications`.

  Each user-facing event type gets a row with in-app and email toggles, grouped
  under readable headings, plus a separate weekly digest toggle (the email flag
  of the `:weekly_digest` type). Every change saves immediately through
  `Kanban.Notifications.update_preference/3` for the signed-in user only;
  event types arriving from the client are matched against the known list and
  never converted to atoms.

  The push settings the Stride app shows are here too, so web and app agree
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9): a Push switch on the
  rows of the eight events that can push (the four that never push show
  none), the mode preset, and quiet hours with the time zone they follow. They
  save through `Kanban.Notifications.update_push_settings/3` with
  `via: :web`; their components are in
  `KanbanWeb.UserLive.PushSettingsComponents`. They show only while
  `Kanban.Devices.show_push?/1` holds (`:mobile_app_preview` is on, or the
  person has a device a push can reach); while they are hidden the server
  refuses their events too, writing nothing.

  A locked scope (`current_scope.notifications_locked`) sees
  `KanbanWeb.NotificationsLocked.panel/1` instead of the toggles. A crafted
  save is still refused by the context, which answers
  `{:error, {:plan_required, :notifications}}`, and the page shows a flash.
  The same refusal on a page opened before enforcement was switched on, or
  before the user left their Organization, switches the page to the locked
  panel, so its toggles do not stay on screen doing nothing.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents
  import KanbanWeb.UserLive.PushSettingsComponents

  alias Kanban.Devices
  alias Kanban.Notifications
  alias Kanban.Notifications.PushSettings
  alias Kanban.Plans
  alias KanbanWeb.NotificationLabels
  alias KanbanWeb.NotificationsLocked

  # Reviews first (reviewing agents' work is the main thing a person does
  # here), then the task and goal lifecycles, board access, and the comment
  # events, which nothing emits yet.
  @groups [
    reviews: [:review_requested, :task_reviewed],
    tasks: [:task_assigned, :task_unclaimed, :claim_expired],
    goals: [:goal_completed, :after_goal_failed, :target_status_changed],
    board_access: [:board_access_changed],
    comments: [:comment_added, :mentioned]
  ]
  @row_types @groups |> Keyword.values() |> List.flatten()
  @push_events ~w(save_push save_push_mode save_quiet_hours)

  # The core checkbox wraps itself in a padded, bottom-margined .fieldset,
  # which left the toggles off-centre and the row gaps uneven. Drop that
  # spacing here, give each label a 44px tap height on phones, and let long
  # label text wrap (the label class keeps it on one line, which overflowed
  # the weekly digest toggle at 320px).
  @toggle_layout "[&_.fieldset]:m-0 [&_.fieldset]:p-0 [&_label]:flex [&_label]:items-center [&_label]:min-h-11 sm:[&_label]:min-h-0 [&_.label]:whitespace-normal"

  @doc false
  # Every event type except :weekly_digest, which has its own toggle.
  def row_types, do: @row_types

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Notification preferences"))
      |> assign(:locked, socket.assigns.current_scope.notifications_locked)
      |> assign(:show_devices?, Devices.show_devices?(socket.assigns.current_scope))
      |> assign(:show_push?, Devices.show_push?(socket.assigns.current_scope))
      |> load_preferences()
      |> load_push()

    {:ok, socket}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{show_push?: false}} = socket)
      when event in @push_events,
      do: refuse_hidden_push(socket)

  def handle_event("save", %{"event_type" => type} = params, socket) do
    case find_row_type(type) do
      nil -> {:noreply, put_flash(socket, :error, gettext("Unknown notification type."))}
      event_type -> save(socket, event_type, Map.take(params, ["in_app", "email"]))
    end
  end

  @impl true
  def handle_event("save_digest", %{"email" => email}, socket) do
    save(socket, :weekly_digest, %{"email" => email})
  end

  @impl true
  def handle_event("save_push", %{"event_type" => type, "push" => push}, socket) do
    case find_push_type(type) do
      nil -> {:noreply, put_flash(socket, :error, gettext("Unknown notification type."))}
      event_type -> save_push(socket, %{"switches" => %{Atom.to_string(event_type) => push}})
    end
  end

  @impl true
  def handle_event("save_push_mode", %{"mode" => mode}, socket) do
    save_push(socket, mode_attrs(mode))
  end

  @impl true
  def handle_event("save_quiet_hours", params, socket) when is_map(params) do
    attrs =
      params
      |> Map.take(~w(quiet_hours_enabled quiet_start quiet_end time_zone))
      |> drop_blank_zone()

    socket = assign(socket, :quiet_params, Map.merge(socket.assigns.quiet_params, attrs))
    save_quiet_hours(socket, changed_quiet_attrs(attrs, socket.assigns.push))
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Unknown notification type."))}
  end

  defp save(socket, event_type, attrs) do
    case Notifications.update_preference(socket.assigns.current_scope, event_type, attrs) do
      {:ok, _preference} ->
        socket =
          socket
          |> load_preferences()
          |> put_flash(:info, gettext("Notification preferences saved."))

        {:noreply, socket}

      {:error, {:plan_required, :notifications}} ->
        {:noreply, lock(socket)}

      {:error, _reason} ->
        socket =
          socket
          |> load_preferences()
          |> put_flash(:error, gettext("Could not save that preference."))

        {:noreply, socket}
    end
  end

  defp save_push(socket, attrs) do
    scope = socket.assigns.current_scope

    case Notifications.update_push_settings(scope, attrs, via: :web, feature: :notifications) do
      {:ok, view} ->
        socket =
          socket
          |> assign_push(view)
          |> put_flash(:info, gettext("Notification preferences saved."))

        {:noreply, socket}

      {:error, {:plan_required, :notifications}} ->
        {:noreply, lock(socket)}

      {:error, reason} ->
        {:noreply, refuse_push(socket, reason)}
    end
  end

  # The loaded view is kept, not re-read, on a changeset: it is what the form
  # shows, so the next quiet hours save still sends only what the person
  # changed.
  defp refuse_push(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:quiet_errors, quiet_errors(changeset))
    |> put_flash(:error, gettext("Could not save that preference."))
  end

  defp refuse_push(socket, _reason) do
    socket
    |> load_push()
    |> put_flash(:error, gettext("Could not save that preference."))
  end

  # A refusal because the person's plan no longer includes notification
  # settings switches the page to the locked panel.
  defp lock(socket) do
    socket
    |> assign(:locked, true)
    |> load_preferences()
    |> load_push()
    |> put_flash(:error, gettext("Notification settings are available to organizations."))
  end

  # The push controls were never rendered, so only a crafted event reaches
  # here: nothing is written and nothing is said. The plan is checked first,
  # so a locked page still locks as it would for a visible control.
  defp refuse_hidden_push(socket) do
    case Plans.check_user(socket.assigns.current_scope, :notifications, surface: :live_view) do
      :ok -> {:noreply, socket}
      {:error, {:plan_required, :notifications}} -> {:noreply, lock(socket)}
    end
  end

  # Nothing differs from what the page loaded, so nothing is written (the
  # context would otherwise store a first row of defaults). The plan is still
  # checked, so a page opened before its settings were locked locks here too.
  defp save_quiet_hours(socket, attrs) when map_size(attrs) == 0 do
    case Plans.check_user(socket.assigns.current_scope, :notifications, surface: :live_view) do
      :ok ->
        socket =
          socket
          |> load_push()
          |> put_flash(:info, gettext("Notification preferences saved."))

        {:noreply, socket}

      {:error, {:plan_required, :notifications}} ->
        {:noreply, lock(socket)}
    end
  end

  defp save_quiet_hours(socket, attrs), do: save_push(socket, attrs)

  # A mode is a preset, so its eight switches are sent with it. The context
  # applies a preset only when the mode differs from the stored one, which a
  # page opened before the app changed the mode would not know.
  defp mode_attrs(mode) when is_binary(mode) do
    case Enum.find(PushSettings.modes(), &(Atom.to_string(&1) == mode)) do
      nil -> %{"mode" => mode}
      known -> %{"mode" => mode, "switches" => preset_switches(known)}
    end
  end

  defp mode_attrs(mode), do: %{"mode" => mode}

  defp preset_switches(mode) do
    mode
    |> PushSettings.preset()
    |> Map.new(fn {type, on} -> {Atom.to_string(type), on} end)
  end

  # The quiet hours form posts every field. Only the fields that differ from
  # what the page last loaded are sent, so a form left open while the app
  # changed another field does not put that field back.
  defp changed_quiet_attrs(attrs, nil), do: attrs

  defp changed_quiet_attrs(attrs, push) do
    loaded = loaded_quiet_values(push)

    Map.reject(attrs, fn {key, value} -> Map.get(loaded, key) == normalize_quiet(key, value) end)
  end

  defp loaded_quiet_values(push) do
    push
    |> quiet_params(nil)
    |> Map.put("time_zone", push.time_zone)
  end

  defp normalize_quiet("quiet_hours_enabled", value) when value in ["true", "false"],
    do: value == "true"

  defp normalize_quiet(_key, value), do: value

  # A blank zone sent to the context is refused even when one is stored, and
  # the picker's prompt sends one, so it is left out instead.
  defp drop_blank_zone(%{"time_zone" => zone} = attrs) when is_binary(zone) do
    if String.trim(zone) == "", do: Map.delete(attrs, "time_zone"), else: attrs
  end

  defp drop_blank_zone(attrs), do: attrs

  defp find_push_type(type) when is_binary(type) do
    Enum.find(PushSettings.push_events(), &(Atom.to_string(&1) == type))
  end

  defp find_push_type(_type), do: nil

  defp find_row_type(type) when is_binary(type) do
    Enum.find(@row_types, &(Atom.to_string(&1) == type))
  end

  defp find_row_type(_type), do: nil

  defp load_preferences(%{assigns: %{locked: true}} = socket),
    do: assign(socket, :preferences, %{})

  defp load_preferences(socket) do
    preferences =
      socket.assigns.current_scope
      |> Notifications.get_preferences()
      |> Map.new(&{&1.event_type, &1})

    assign(socket, :preferences, preferences)
  end

  defp load_push(%{assigns: %{locked: true}} = socket) do
    socket
    |> assign(:push, nil)
    |> assign(:quiet_params, %{})
    |> assign(:quiet_errors, %{})
  end

  defp load_push(socket) do
    assign_push(socket, Notifications.get_push_settings(socket.assigns.current_scope))
  end

  defp assign_push(socket, view) do
    socket
    |> assign(:push, view)
    |> assign(:quiet_params, quiet_params(view, socket.assigns[:timezone]))
    |> assign(:quiet_errors, %{})
  end

  defp groups, do: @groups

  defp group_title(:reviews), do: gettext("Reviews")
  defp group_title(:tasks), do: gettext("Tasks and agents")
  defp group_title(:goals), do: gettext("Goals and targets")
  defp group_title(:board_access), do: gettext("Board access")
  defp group_title(:comments), do: gettext("Comments and mentions")

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:groups, groups())
      |> assign(:toggle_layout, @toggle_layout)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <:breadcrumbs>
        <.link navigate={~p"/users/settings"} style="color: var(--ink-3); text-decoration: none;">
          {gettext("Settings")}
        </.link>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("Notifications")}</span>
      </:breadcrumbs>

      <.settings_shell active={:notifications} show_devices={@show_devices?}>
        <div data-notification-preferences>
          <h2 style="margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -0.015em; color: var(--ink);">
            {gettext("Notification preferences")}
          </h2>
          <p style="margin: 4px 0 0; font-size: 12px; color: var(--ink-3); line-height: 1.5; text-wrap: pretty;">
            {gettext(
              "Choose which events reach you and how. Changes save as soon as you toggle them."
            )}
          </p>
        </div>

        <NotificationsLocked.panel :if={@locked} id="notification-preferences-locked" />

        <.push_mode_card :if={!@locked and @show_push?} push={@push} />

        <.settings_card
          :for={{group, types} <- @groups}
          :if={!@locked}
          id={"group-#{group}"}
          title={group_title(group)}
          level={3}
          compact
        >
          <div
            :for={type <- types}
            id={"pref-row-#{type}"}
            class="flex flex-col @md:flex-row @md:items-center gap-2 @md:gap-4"
            style="padding: 10px 0; border-bottom: 1px solid var(--line);"
          >
            <div style="flex: 1; min-width: 0;">
              <div
                id={"pref-#{type}-name"}
                style="font-size: 13px; font-weight: 600; color: var(--ink);"
              >
                {NotificationLabels.category(type)}
              </div>
              <div style="font-size: 12px; color: var(--ink-3); line-height: 1.45; text-wrap: pretty;">
                {NotificationLabels.description(type)}
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-5 min-w-0">
              <form
                id={"pref-#{type}"}
                phx-change="save"
                class={["flex gap-5", @toggle_layout]}
                style="margin: 0;"
              >
                <input type="hidden" name="event_type" value={type} />
                <.input
                  type="checkbox"
                  id={"pref-#{type}-in_app"}
                  name="in_app"
                  aria-describedby={"pref-#{type}-name"}
                  value={@preferences[type].in_app}
                  label={gettext("In-app")}
                />
                <.input
                  type="checkbox"
                  id={"pref-#{type}-email"}
                  name="email"
                  aria-describedby={"pref-#{type}-name"}
                  value={@preferences[type].email}
                  label={gettext("Email")}
                />
              </form>
              <.push_switch
                :if={@show_push?}
                type={type}
                switches={@push.switches}
                toggle_layout={@toggle_layout}
              />
            </div>
          </div>
        </.settings_card>

        <.settings_card
          :if={!@locked}
          id="group-digest"
          title={gettext("Weekly digest")}
          level={3}
          compact
        >
          <form
            id="pref-weekly_digest"
            phx-change="save_digest"
            class={@toggle_layout}
            style="margin: 0; padding: 10px 0;"
          >
            <.input
              type="checkbox"
              id="pref-weekly_digest-email"
              name="email"
              value={@preferences[:weekly_digest].email}
              label={gettext("Email me a weekly summary of activity on my boards")}
            />
          </form>
        </.settings_card>

        <.quiet_hours_card
          :if={!@locked and @show_push?}
          params={@quiet_params}
          errors={@quiet_errors}
          zone_options={zone_options(@push.time_zone, @timezone)}
          toggle_layout={@toggle_layout}
        />
      </.settings_shell>
    </Layouts.app>
    """
  end
end
