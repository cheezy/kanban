defmodule KanbanWeb.UserLive.Registration do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame
  import KanbanWeb.FormHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame>
      <:footer_switch>
        <span>{gettext("Already have an account?")}</span>
        <.link
          navigate={~p"/users/log-in"}
          style="color: var(--ink); font-weight: 500; margin-left: 4px; text-decoration: none;"
        >
          {gettext("Sign in")} <span aria-hidden="true">→</span>
        </.link>
      </:footer_switch>

      <div>
        <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
          {gettext("Create your account")}
        </h1>
      </div>

      <.form
        for={@form}
        id="registration_form"
        action={~p"/users/register"}
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        style="margin-top: 16px; display: flex; flex-direction: column; gap: 12px;"
      >
        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Your name")}
          </span>
          <input
            type="text"
            name={@form[:name].name}
            id={@form[:name].id}
            value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
            autocomplete="name"
            phx-mounted={JS.focus()}
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
          />
          <.field_errors errors={@form[:name].errors} />
        </label>

        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Work email")}
          </span>
          <input
            type="email"
            name={@form[:email].name}
            id={@form[:email].id}
            value={Phoenix.HTML.Form.normalize_value("email", @form[:email].value)}
            autocomplete="username"
            required
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
          />
          <.field_errors errors={@form[:email].errors} />
        </label>

        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Password")}
          </span>
          <input
            type="password"
            name={@form[:password].name}
            id={@form[:password].id}
            autocomplete="new-password"
            required
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
          />
          <span style="font-size: 11px; color: var(--ink-3); line-height: 1.45;">
            {gettext("At least 12 characters")}
          </span>
          <.field_errors errors={@form[:password].errors} />
        </label>

        <label style="display: flex; align-items: flex-start; gap: 8px; font-size: 12px; color: var(--ink-2); line-height: 1.5; margin-top: 2px;">
          <span style="padding-top: 2px;">
            <input
              type="checkbox"
              checked
              required
              style="width: 14px; height: 14px; border-radius: 3px; accent-color: var(--ink); cursor: pointer; margin: 0;"
            />
          </span>
          <span>
            {gettext("I agree to the")}
            <.link navigate={~p"/terms"} style="color: var(--ink); text-decoration: underline;">
              {gettext("Terms of Service")}
            </.link>
            {gettext("and")}
            <.link
              navigate={~p"/acceptable-use"}
              style="color: var(--ink); text-decoration: underline;"
            >
              {gettext("Acceptable Use Policy")}
            </.link>
            {gettext("— including the agent-action attribution clause.")}
          </span>
        </label>

        <div style="margin-top: 4px;">
          <.primary_full_button
            kbd="↵"
            type="submit"
            phx-disable-with={gettext("Creating account...")}
          >
            {gettext("Create account")}
          </.primary_full_button>
        </div>
      </.form>
    </.auth_frame>
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
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: true,
        hash_password: false
      )

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
