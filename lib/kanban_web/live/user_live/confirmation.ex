defmodule KanbanWeb.UserLive.Confirmation do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthComponents

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_form
        title={
          if @confirmed,
            do: gettext("Account Confirmed!"),
            else: gettext("Confirming your account...")
        }
        icon_gradient="from-green-500 to-green-600"
        icon_path="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
      >
        <:subtitle :if={@confirmed}>
          {gettext("Your account has been confirmed successfully. You can now log in.")}
        </:subtitle>

        <%= if @confirmed do %>
          <.link navigate={~p"/users/log-in"} class="btn btn-primary w-full">
            {gettext("Go to login")} <span aria-hidden="true">→</span>
          </.link>
        <% else %>
          <div class="flex items-center justify-center">
            <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-primary"></div>
          </div>
        <% end %>
      </.auth_form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if connected?(socket) do
      send(self(), :confirm)
    end

    {:ok, assign(socket, token: token, confirmed: false)}
  end

  @impl true
  def handle_info(:confirm, socket) do
    case Accounts.confirm_user(socket.assigns.token) do
      {:ok, _user} ->
        {:noreply, assign(socket, confirmed: true)}

      {:error, :already_confirmed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("This account has already been confirmed. You can log in."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, :invalid_token} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Confirmation link is invalid or has expired."))
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end
end
