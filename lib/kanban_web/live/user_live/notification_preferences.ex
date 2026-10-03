defmodule KanbanWeb.UserLive.NotificationPreferences do
  @moduledoc """
  Per-event notification preferences at `/users/notifications`.

  Each user-facing event type gets a row with in-app and email toggles, grouped
  under readable headings, plus a separate weekly digest toggle (the email flag
  of the `:weekly_digest` type). Every change saves immediately through
  `Kanban.Notifications.update_preference/3` for the signed-in user only;
  event types arriving from the client are matched against the known list and
  never converted to atoms.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.UserLive.SettingsComponents

  alias Kanban.Notifications
  alias KanbanWeb.NotificationLabels

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
      |> load_preferences()

    {:ok, socket}
  end

  @impl true
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

      {:error, _reason} ->
        socket =
          socket
          |> load_preferences()
          |> put_flash(:error, gettext("Could not save that preference."))

        {:noreply, socket}
    end
  end

  defp find_row_type(type) when is_binary(type) do
    Enum.find(@row_types, &(Atom.to_string(&1) == type))
  end

  defp find_row_type(_type), do: nil

  defp load_preferences(socket) do
    preferences =
      socket.assigns.current_scope
      |> Notifications.get_preferences()
      |> Map.new(&{&1.event_type, &1})

    assign(socket, :preferences, preferences)
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

      <.settings_shell active={:notifications}>
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

        <.settings_card
          :for={{group, types} <- @groups}
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
          </div>
        </.settings_card>

        <.settings_card id="group-digest" title={gettext("Weekly digest")} level={3} compact>
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
      </.settings_shell>
    </Layouts.app>
    """
  end
end
