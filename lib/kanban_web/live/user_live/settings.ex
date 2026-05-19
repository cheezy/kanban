defmodule KanbanWeb.UserLive.Settings do
  use KanbanWeb, :live_view

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="stride-screen" style="padding: 20px 28px 28px;">
        <header style="display: flex; align-items: flex-start; gap: 16px; padding-bottom: 14px;">
          <div style="flex: 1; min-width: 0;">
            <h1 style="margin: 0; font-size: 24px; font-weight: 600; letter-spacing: -0.025em; color: var(--ink);">
              {gettext("Settings")}
            </h1>
            <p style="margin: 6px 0 0; font-size: 13px; color: var(--ink-2); max-width: 720px; text-wrap: pretty; line-height: 1.55;">
              {gettext(
                "Manage your account profile and password. Changes apply to your account immediately."
              )}
            </p>
          </div>
        </header>

        <div style="flex: 1; display: flex; min-height: 0; gap: 28px;">
          <nav style="width: 184px; flex-shrink: 0; padding-top: 4px; display: flex; flex-direction: column; gap: 1px;">
            <.section_link
              href="#profile"
              active
              label={gettext("Profile")}
              hint={gettext("name · email")}
            />
            <.section_link
              href="#password"
              label={gettext("Password")}
              hint={gettext("change credentials")}
            />
          </nav>

          <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 18px;">
            <.settings_card
              id="profile"
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
                    style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 12.5px; color: var(--ink); outline: none; font-family: inherit;"
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
                    style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 12.5px; color: var(--ink); outline: none; font-family: inherit;"
                  />
                  <.field_errors errors={@email_form[:email].errors} />
                </.set_field>

                <div style="margin-top: 4px;">
                  <button
                    type="submit"
                    phx-disable-with={gettext("Saving...")}
                    style="height: 32px; padding: 0 14px; border-radius: 5px; background: var(--ink); color: var(--color-primary-content); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 2px rgba(0, 0, 0, 0.15);"
                  >
                    {gettext("Update profile")}
                  </button>
                </div>
              </.form>
            </.settings_card>

            <.settings_card
              id="password"
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
                  <input
                    type="password"
                    name={@password_form[:password].name}
                    id={@password_form[:password].id}
                    autocomplete="new-password"
                    required
                    style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 12.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
                  />
                  <.field_errors errors={@password_form[:password].errors} />
                </.set_field>

                <.set_field label={gettext("Confirm new password")} hint={nil}>
                  <input
                    type="password"
                    name={@password_form[:password_confirmation].name}
                    id={@password_form[:password_confirmation].id}
                    autocomplete="new-password"
                    style="padding: 0 10px; height: 32px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 12.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
                  />
                  <.field_errors errors={@password_form[:password_confirmation].errors} />
                </.set_field>

                <div style="margin-top: 4px;">
                  <button
                    type="submit"
                    phx-disable-with={gettext("Saving...")}
                    style="height: 32px; padding: 0 14px; border-radius: 5px; background: var(--ink); color: var(--color-primary-content); border: none; font-size: 12.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 2px rgba(0, 0, 0, 0.15);"
                  >
                    {gettext("Save password")}
                  </button>
                </div>
              </.form>
            </.settings_card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------------
  # Local components (mirror board-settings.jsx primitives)
  # -------------------------------------------------------------------------

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :active, :boolean, default: false

  defp section_link(assigns) do
    ~H"""
    <a
      href={@href}
      style={[
        "display: flex; flex-direction: column; gap: 1px; padding: 7px 10px; border-radius: 5px;",
        if(@active,
          do: "background: var(--surface); box-shadow: inset 0 0 0 1px var(--line);",
          else: "background: transparent;"
        ),
        "text-decoration: none; cursor: pointer;"
      ]}
    >
      <span style={[
        "font-size: 12.5px;",
        if(@active,
          do: "font-weight: 600; color: var(--ink);",
          else: "font-weight: 500; color: var(--ink-2);"
        )
      ]}>
        {@label}
      </span>
      <span
        :if={@hint}
        style="font-size: 10.5px; font-family: var(--font-mono); color: var(--ink-4); letter-spacing: -0.01em;"
      >
        {@hint}
      </span>
    </a>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp settings_card(assigns) do
    ~H"""
    <section
      id={@id}
      style="background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden;"
    >
      <header style="padding: 14px 18px 12px; border-bottom: 1px solid var(--line); display: flex; align-items: flex-start; gap: 12px; background: var(--surface);">
        <div style="flex: 1; min-width: 0;">
          <h2 style="margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -0.015em; color: var(--ink);">
            {@title}
          </h2>
          <p
            :if={@hint}
            style="margin: 4px 0 0; font-size: 12px; color: var(--ink-3); line-height: 1.5; text-wrap: pretty;"
          >
            {@hint}
          </p>
        </div>
      </header>
      <div style="padding: 18px;">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

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

  attr :errors, :list, default: []

  defp field_errors(assigns) do
    ~H"""
    <span :for={msg <- @errors} style="font-size: 11.5px; color: var(--st-blocked);">
      {translate_error(msg)}
    </span>
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

    {:ok, socket}
  end

  @impl true
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
