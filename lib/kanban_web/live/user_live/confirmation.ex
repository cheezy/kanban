defmodule KanbanWeb.UserLive.Confirmation do
  use KanbanWeb, :live_view

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="bg-base-100 rounded-2xl shadow-xl p-8 border border-base-300 text-center">
          <div class="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-green-500 to-green-600 rounded-xl shadow-lg mb-4">
            <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </div>

          <%= if @confirmed do %>
            <.header>
              <p class="text-2xl font-bold text-base-content mb-6">{gettext("Account Confirmed!")}</p>
              <:subtitle>
                <p class="text-base-content opacity-70 mt-2">
                  {gettext("Your account has been confirmed successfully. You can now log in.")}
                </p>
              </:subtitle>
            </.header>

            <.link
              navigate={~p"/users/log-in"}
              class="inline-block w-full bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white font-semibold py-3 rounded-lg shadow-md hover:shadow-lg transition-all"
            >
              {gettext("Go to login")} <span aria-hidden="true">→</span>
            </.link>
          <% else %>
            <div class="flex items-center justify-center">
              <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
            </div>
            <p class="text-base-content opacity-70 mt-4">{gettext("Confirming your account...")}</p>
          <% end %>
        </div>
      </div>
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
