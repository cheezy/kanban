defmodule KanbanWeb.UserLive.Settings do
  use KanbanWeb, :live_view

  import KanbanWeb.FormHelpers
  import KanbanWeb.LockedFeature, only: [locked_feature: 1]
  import KanbanWeb.UserLive.SettingsComponents

  alias Kanban.Accounts
  alias Kanban.Devices
  alias Kanban.Plans
  alias Kanban.SSO
  alias KanbanWeb.UserAuth

  @sections ["profile", "password", "two_factor", "sso", "devices", "danger_zone"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell active={@section} show_devices={@show_devices?} tabs>
        <.settings_card
          :if={@section == :profile}
          id="profile"
          tab={:profile}
          title={gettext("Profile")}
          hint={
            gettext(
              "Your name and email address. Email changes require confirmation by clicking a link sent to the new address."
            )
          }
        >
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            style="display: flex; flex-direction: column; gap: 14px;"
          >
            <.set_field label={gettext("Name")} hint={nil}>
              <input
                type="text"
                name={@email_form[:name].name}
                id={@email_form[:name].id}
                value={Phoenix.HTML.Form.normalize_value("text", @email_form[:name].value)}
                autocomplete="name"
                style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-input); font-size: 12.5px; color: var(--ink); outline: none; font-family: inherit;"
              />
              <.field_errors errors={@email_form[:name].errors} />
            </.set_field>

            <.set_field label={gettext("Email")} hint={nil}>
              <input
                type="email"
                name={@email_form[:email].name}
                id={@email_form[:email].id}
                value={Phoenix.HTML.Form.normalize_value("email", @email_form[:email].value)}
                autocomplete="username"
                required
                style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-input); font-size: 12.5px; color: var(--ink); outline: none; font-family: inherit;"
              />
              <.field_errors errors={@email_form[:email].errors} />
            </.set_field>

            <div style="margin-top: 4px;">
              <button
                type="submit"
                phx-disable-with={gettext("Saving...")}
                style="height: 32px; padding: 0 14px; border-radius: 5px; background: var(--ink); color: var(--color-base-100); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 2px rgba(0, 0, 0, 0.15);"
              >
                {gettext("Update profile")}
              </button>
            </div>
          </.form>
        </.settings_card>

        <.settings_card
          :if={@section == :password}
          id="password"
          tab={:password}
          title={gettext("Password")}
          hint={
            gettext(
              "Choose a strong password and confirm it. You will stay signed in on this device after a successful change."
            )
          }
        >
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            style="display: flex; flex-direction: column; gap: 14px;"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              autocomplete="username"
              value={@current_email}
            />

            <.set_field label={gettext("New password")} hint={gettext("At least 12 characters")}>
              <%!-- `value` is REQUIRED on a password input inside a
                  phx-change form: LiveView's DOM patch assigns
                  `fromEl.value = toEl.value` to every input that is not focused,
                  so an unrendered value let typing in the confirmation field
                  wipe whatever had been typed here. --%>
              <input
                type="password"
                name={@password_form[:password].name}
                id={@password_form[:password].id}
                value={
                  Phoenix.HTML.Form.normalize_value(
                    "password",
                    @password_form[:password].value
                  )
                }
                autocomplete="new-password"
                required
                style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-input); font-size: 12.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
              />
              <.field_errors errors={@password_form[:password].errors} />
            </.set_field>

            <.set_field label={gettext("Confirm new password")} hint={nil}>
              <input
                type="password"
                name={@password_form[:password_confirmation].name}
                id={@password_form[:password_confirmation].id}
                value={
                  Phoenix.HTML.Form.normalize_value(
                    "password",
                    @password_form[:password_confirmation].value
                  )
                }
                autocomplete="new-password"
                style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-input); font-size: 12.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
              />
              <.field_errors errors={@password_form[:password_confirmation].errors} />
            </.set_field>

            <div style="margin-top: 4px;">
              <button
                type="submit"
                phx-disable-with={gettext("Saving...")}
                style="height: 32px; padding: 0 14px; border-radius: 5px; background: var(--ink); color: var(--color-base-100); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 2px rgba(0, 0, 0, 0.15);"
              >
                {gettext("Save password")}
              </button>
            </div>
          </.form>
        </.settings_card>

        <.settings_card
          :if={@section == :two_factor}
          id="two_factor"
          tab={:two_factor}
          title={gettext("Two-factor authentication")}
          hint={
            gettext(
              "Protect your account with a code from an authenticator app in addition to your password."
            )
          }
        >
          <.live_component
            module={KanbanWeb.UserLive.TwoFactorComponent}
            id="two-factor"
            user={@current_scope.user}
          />
        </.settings_card>

        <.settings_card
          :if={@section == :sso}
          id="sso"
          tab={:sso}
          title={gettext("Single sign-on")}
          hint={
            gettext(
              "Sign in through your Organization's identity provider, which also handles multi-factor authentication."
            )
          }
        >
          <.locked_feature :if={@sso_locked?} feature={:sso} variant={:panel} id="sso-locked" />
          <p
            :if={!@sso_locked? && @sso_linked?}
            id="sso-linked"
            style="margin: 0; font-size: 13px; color: var(--ink-2); line-height: 1.55;"
          >
            {gettext(
              "Your account signs in through your Organization's identity provider. Use Sign in with SSO on the sign-in page."
            )}
          </p>
          <p
            :if={!@sso_locked? && !@sso_linked?}
            id="sso-not-linked"
            style="margin: 0; font-size: 13px; color: var(--ink-2); line-height: 1.55;"
          >
            {gettext(
              "Your Organization's org-admins set up single sign-on in the org console. Once your email domain is verified there, use Sign in with SSO on the sign-in page."
            )}
          </p>
        </.settings_card>

        <.settings_card
          :if={@section == :devices and @show_devices?}
          id="devices"
          tab={:devices}
          title={gettext("Devices")}
          hint={
            gettext(
              "The phones and tablets signed in to your account. Revoke one you no longer use or have lost: it is signed out at once."
            )
          }
          compact
        >
          <.live_component
            module={KanbanWeb.UserLive.DevicesComponent}
            id="devices-section"
            current_scope={@current_scope}
            rev={@devices_rev}
          />
        </.settings_card>

        <.settings_card
          :if={@section == :danger_zone}
          id="danger_zone"
          tab={:danger_zone}
          title={gettext("Delete account")}
          hint={
            gettext(
              "Permanently delete your account. Available to everyone, with or without an Organization."
            )
          }
        >
          <.live_component
            module={KanbanWeb.UserLive.DangerZoneComponent}
            id="danger-zone"
            current_scope={@current_scope}
          />
        </.settings_card>
      </.settings_shell>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------------
  # Local components (mirror board-settings.jsx primitives); the shell, menu
  # and cards are shared with notification preferences (SettingsComponents).
  # -------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :hint, :any, default: nil
  slot :inner_block, required: true

  defp set_field(assigns) do
    ~H"""
    <label style="display: flex; flex-direction: column; gap: 5px;">
      <span style="display: flex; align-items: baseline; gap: 8px; font-size: 12px; font-weight: 500; color: var(--ink-2);">
        {@label}
      </span>
      {render_slot(@inner_block)}
      <span
        :if={@hint}
        style="font-size: 11px; color: var(--ink-3); text-wrap: pretty; line-height: 1.45;"
      >
        {@hint}
      </span>
    </label>
    """
  end

  # -------------------------------------------------------------------------
  # mount + handle_event — untouched from before W658
  # -------------------------------------------------------------------------

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:section, :profile)
      |> assign(:devices_rev, 0)
      |> assign_scope_flags()
      |> subscribe_devices()

    {:ok, socket}
  end

  # The assigns read from the signed-in scope: whether the Devices section
  # shows (W2910) and whether SSO locks or is linked.
  defp assign_scope_flags(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:show_devices?, Devices.show_devices?(scope))
    |> assign(:sso_locked?, not Plans.user_unlocked?(socket.assigns.current_scope))
    |> assign(:sso_linked?, SSO.user_has_identity?(scope.user))
  end

  # The other settings pages link here with ?section=password (or two_factor,
  # sso, devices, danger_zone) to open that tab.
  @impl true
  def handle_params(%{"section" => section}, _uri, socket) when section in @sections do
    {:noreply, open_section(socket, section)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_section", %{"section" => section}, socket)
      when section in @sections do
    {:noreply, open_section(socket, section)}
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    if email_changed?(user_params, user) do
      request_email_change(socket, user, user_params)
    else
      save_name_only(socket, user, user_params)
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # Sent by DangerZoneComponent once the account is deleted: close the user's
  # other open LiveViews. This page's own session is cleared by the log-out
  # form the component triggers.
  @impl true
  def handle_info({:account_deleted, session_tokens}, socket) do
    UserAuth.disconnect_sessions(session_tokens)
    {:noreply, socket}
  end

  # A new :devices_rev updates the Devices component in this same render,
  # which reads the person's devices again. Revoking the last device of a
  # person without :mobile_app_preview hides the section; if it was open,
  # Profile opens and the revoke is reported there, as the section would have.
  def handle_info({:device_revoked, _device_id}, socket) do
    socket =
      socket
      |> update(:devices_rev, &(&1 + 1))
      |> assign(:show_devices?, Devices.show_devices?(socket.assigns.current_scope))

    {:noreply, leave_hidden_devices(socket)}
  end

  defp leave_hidden_devices(%{assigns: %{show_devices?: false, section: :devices}} = socket) do
    socket
    |> assign(:section, :profile)
    |> put_flash(:info, gettext("Device revoked."))
  end

  defp leave_hidden_devices(socket), do: socket

  # Devices is shown only while it can matter (Kanban.Devices.show_devices?/1);
  # asking for it while it is hidden opens Profile instead.
  defp open_section(%{assigns: %{show_devices?: false}} = socket, "devices"),
    do: assign(socket, :section, :profile)

  defp open_section(socket, section),
    do: assign(socket, :section, String.to_existing_atom(section))

  # A device revoked on another page, by the person, an org-admin or the
  # device itself, leaves the Devices section at once (handle_info/2).
  defp subscribe_devices(socket) do
    if connected?(socket), do: Devices.subscribe_devices(socket.assigns.current_scope)
    socket
  end

  defp email_changed?(user_params, user) do
    submitted = Map.get(user_params, "email")
    is_binary(submitted) and submitted != user.email
  end

  defp request_email_change(socket, user, user_params) do
    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        updated_user = Ecto.Changeset.apply_action!(changeset, :insert)

        _ = Accounts.update_user_name(user, user_params)

        Accounts.deliver_user_update_email_instructions(
          updated_user,
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, put_flash(socket, :info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  defp save_name_only(socket, user, user_params) do
    case Accounts.update_user_name(user, user_params) do
      {:ok, updated_user} ->
        email_form =
          updated_user
          |> Accounts.change_user_email(%{}, validate_unique: false)
          |> to_form()

        {:noreply,
         socket
         |> assign(:email_form, email_form)
         |> put_flash(:info, gettext("Profile updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :update))}
    end
  end
end
