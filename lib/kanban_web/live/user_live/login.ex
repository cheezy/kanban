defmodule KanbanWeb.UserLive.Login do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame flash={@flash}>
      <:footer_switch>
        <span>{gettext("New to Stride?")}</span>
        <.link
          navigate={~p"/users/register"}
          style="color: var(--ink); font-weight: 500; margin-left: 4px; text-decoration: none;"
        >
          {gettext("Create an account")} <span aria-hidden="true">→</span>
        </.link>
      </:footer_switch>

      <div>
        <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
          {gettext("Sign in")}
        </h1>
        <p style="margin: 8px 0 0; font-size: 13.5px; color: var(--ink-3);">
          {if @current_scope,
            do: gettext("You need to reauthenticate to perform sensitive actions on your account."),
            else: gettext("Welcome back. Use the same method you used last time.")}
        </p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_password"
        action={~p"/users/log-in"}
        phx-submit="submit_password"
        phx-trigger-action={@trigger_submit}
        style="margin-top: 28px; display: flex; flex-direction: column; gap: 12px;"
      >
        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Email")}
          </span>
          <input
            type="email"
            name={f[:email].name}
            id={f[:email].id}
            value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
            readonly={!!@current_scope}
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
          />
        </label>

        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="display: flex; align-items: baseline; gap: 8px; font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Password")}
            <span style="flex: 1;"></span>
            <.link
              navigate={~p"/users/forgot-password"}
              style="font-size: 11.5px; color: var(--ink-3); text-decoration: none;"
            >
              {gettext("Forgot?")}
            </.link>
          </span>
          <input
            type="password"
            name={f[:password].name}
            id={f[:password].id}
            autocomplete="current-password"
            required
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
          />
        </label>

        <label style="display: flex; align-items: center; gap: 8px; font-size: 12.5px; color: var(--ink-2); cursor: pointer;">
          <input type="hidden" name={f[:remember_me].name} value="false" />
          <input
            type="checkbox"
            name={f[:remember_me].name}
            id={f[:remember_me].id}
            value="true"
            style="width: 14px; height: 14px; border-radius: 3px; accent-color: var(--ink); cursor: pointer; margin: 0;"
          />
          {gettext("Keep me signed in on this device")}
        </label>

        <div style="margin-top: 4px;">
          <.primary_full_button kbd="↵" type="submit">{gettext("Sign in")}</.primary_full_button>
        </div>
      </.form>

      <p style="margin: 14px 0 0; text-align: center;">
        <.link
          navigate={~p"/users/confirmation-pending"}
          style="font-size: 12px; color: var(--ink-3); text-decoration: none;"
        >
          {gettext("Resend confirmation email")}
        </.link>
      </p>
    </.auth_frame>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
