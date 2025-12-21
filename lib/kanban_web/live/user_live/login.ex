defmodule KanbanWeb.UserLive.Login do
  use KanbanWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="bg-base-100 rounded-2xl shadow-xl p-8 border border-base-300">
          <div class="text-center mb-8">
            <div class="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-blue-600 to-blue-700 rounded-xl shadow-lg mb-4">
              <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
                />
              </svg>
            </div>
            <.header>
              <p class="text-2xl font-bold text-base-content">{gettext("Welcome Back")}</p>
              <:subtitle>
                <%= if @current_scope do %>
                  <p class="text-base-content opacity-70 mt-2">
                    {gettext(
                      "You need to reauthenticate to perform sensitive actions on your account."
                    )}
                  </p>
                <% else %>
                  <p class="text-base-content opacity-70 mt-2">
                    {gettext("Don't have an account?")}
                    <.link
                      navigate={~p"/users/register"}
                      class="font-semibold text-blue-600 hover:text-blue-800 hover:underline"
                      phx-no-format
                    >{gettext("Sign up")}</.link>
                    {gettext("for free.")}
                  </p>
                <% end %>
              </:subtitle>
            </.header>
          </div>

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
            <.button class="w-full bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white font-semibold py-3 rounded-lg shadow-md hover:shadow-lg transition-all mt-4">
              {gettext("Log in")} <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <div class="mt-6 text-center text-sm">
            <.link
              href={~p"/users/forgot-password"}
              class="font-medium text-blue-600 hover:text-blue-800 hover:underline"
            >
              {gettext("Forgot your password?")}
            </.link>
          </div>
        </div>
      </div>
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
