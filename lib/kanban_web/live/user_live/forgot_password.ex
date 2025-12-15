defmodule KanbanWeb.UserLive.ForgotPassword do
  use KanbanWeb, :live_view

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="bg-white rounded-2xl shadow-xl p-8 border border-gray-100">
          <div class="text-center mb-8">
            <div class="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-blue-600 to-blue-700 rounded-xl shadow-lg mb-4">
              <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"
                />
              </svg>
            </div>
            <.header>
              <p class="text-2xl font-bold text-gray-900">{gettext("Forgot your password?")}</p>
              <:subtitle>
                <p class="text-gray-600 mt-2">
                  {gettext(
                    "We'll send you an email with instructions to reset your password."
                  )}
                </p>
              </:subtitle>
            </.header>
          </div>

          <.form :let={f} for={@form} id="reset_password_form" phx-submit="send_email">
            <.input
              field={f[:email]}
              type="email"
              placeholder={gettext("Email")}
              label={gettext("Email")}
              required
              phx-mounted={JS.focus()}
            />
            <.button class="w-full bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white font-semibold py-3 rounded-lg shadow-md hover:shadow-lg transition-all mt-4">
              {gettext("Send password reset instructions")}
            </.button>
          </.form>

          <div class="mt-6 text-center text-sm">
            <.link
              href={~p"/users/log-in"}
              class="font-medium text-blue-600 hover:text-blue-800 hover:underline"
            >
              {gettext("Back to log in")}
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions to reset your password shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
