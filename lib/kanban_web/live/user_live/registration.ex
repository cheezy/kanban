defmodule KanbanWeb.UserLive.Registration do
  use KanbanWeb, :live_view

  alias Kanban.Accounts
  alias Kanban.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6 py-8">
        <div class="bg-base-100 rounded-2xl shadow-xl p-8 border border-base-300">
          <div class="text-center mb-8">
            <div class="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-orange-500 to-orange-600 rounded-xl shadow-lg mb-4">
              <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M18 9v3m0 0v3m0-3h3m-3 0h-3m-2-5a4 4 0 11-8 0 4 4 0 018 0zM3 20a6 6 0 0112 0v1H3v-1z"
                />
              </svg>
            </div>
            <.header>
              <p class="text-2xl font-bold text-base-content">{gettext("Create Your Account")}</p>
              <:subtitle>
                <p class="text-base-content opacity-70 mt-2">
                  {gettext("Already registered?")}
                  <.link
                    navigate={~p"/users/log-in"}
                    class="font-semibold text-blue-600 hover:text-blue-800 hover:underline"
                  >
                    {gettext("Log in")}
                  </.link>
                  {gettext("to your account.")}
                </p>
              </:subtitle>
            </.header>
          </div>

          <.form
            for={@form}
            id="registration_form"
            action={~p"/users/register"}
            phx-submit="save"
            phx-change="validate"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              autocomplete="name"
              phx-mounted={JS.focus()}
            />

            <.input
              field={@form[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              required
            />

            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              autocomplete="new-password"
              required
            />

            <.button
              phx-disable-with={gettext("Creating account...")}
              class="w-full bg-gradient-to-r from-orange-500 to-orange-600 hover:from-orange-600 hover:to-orange-700 text-white font-semibold py-3 rounded-lg shadow-md hover:shadow-lg transition-all mt-6"
            >
              {gettext("Create an account")}
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: KanbanWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)

    socket =
      socket
      |> assign_form(changeset)
      |> assign(:trigger_submit, false)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # Validate the user params without actually creating the user
    changeset =
      Accounts.change_user_registration(%User{}, user_params, validate_unique: true, hash_password: false)

    if changeset.valid? do
      # Validation passed, trigger form submission to controller which will create user and log in
      {:noreply, assign(socket, :trigger_submit, true)}
    else
      # Validation failed, show errors
      {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
