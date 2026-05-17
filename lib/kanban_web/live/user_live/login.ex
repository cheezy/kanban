defmodule KanbanWeb.UserLive.Login do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_form
        title={gettext("Welcome Back")}
        icon_path="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
      >
        <:subtitle>
          <%= if @current_scope do %>
            {gettext("You need to reauthenticate to perform sensitive actions on your account.")}
          <% else %>
            {gettext("Don't have an account?")}
            <.link
              navigate={~p"/users/register"}
              class="font-semibold text-primary hover:underline"
              phx-no-format
            >{gettext("Sign up")}</.link>
            {gettext("for free.")}
          <% end %>
        </:subtitle>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            required
          />
          <.input
            field={@form[:remember_me]}
            type="checkbox"
            label={gettext("Stay logged in")}
          />
          <.button variant="primary" class="btn btn-primary w-full mt-4">
            {gettext("Log in")} <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <:footer>
          <.link
            href={~p"/users/forgot-password"}
            class="font-medium text-primary hover:underline"
          >
            {gettext("Forgot your password?")}
          </.link>
        </:footer>
      </.auth_form>
    </Layouts.app>
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
