defmodule KanbanWeb.UserLive.ForgotPassword do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthComponents

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_form
        title={gettext("Forgot your password?")}
        subtitle={gettext("We'll send you an email with instructions to reset your password.")}
      >
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
      </.auth_form>
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
