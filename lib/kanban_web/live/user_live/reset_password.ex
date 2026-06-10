defmodule KanbanWeb.UserLive.ResetPassword do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame
  import KanbanWeb.FormHelpers

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame>
      <:footer_switch>
        <.link
          navigate={~p"/users/log-in"}
          style="color: var(--ink-2); text-decoration: none;"
        >
          <span aria-hidden="true">←</span> {gettext("Back to sign in")}
        </.link>
      </:footer_switch>

      <div>
        <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
          {gettext("Reset password")}
        </h1>
        <p style="margin: 8px 0 0; font-size: 13.5px; color: var(--ink-3); text-wrap: pretty;">
          {gettext("Choose a new password for your account.")}
        </p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="reset_password_form"
        phx-submit="reset_password"
        phx-change="validate"
        style="margin-top: 28px; display: flex; flex-direction: column; gap: 12px;"
      >
        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("New password")}
          </span>
          <input
            type="password"
            name={f[:password].name}
            id={f[:password].id}
            autocomplete="new-password"
            required
            phx-mounted={JS.focus()}
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
          />
          <span style="font-size: 11px; color: var(--ink-3); line-height: 1.45;">
            {gettext("At least 12 characters")}
          </span>
          <.field_errors errors={f[:password].errors} />
        </label>

        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {gettext("Confirm new password")}
          </span>
          <input
            type="password"
            name={f[:password_confirmation].name}
            id={f[:password_confirmation].id}
            autocomplete="new-password"
            required
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: var(--font-mono);"
          />
          <.field_errors errors={f[:password_confirmation].errors} />
        </label>

        <div style="margin-top: 4px;">
          <.primary_full_button kbd="↵" type="submit">
            {gettext("Reset password")}
          </.primary_full_button>
        </div>
      </.form>
    </.auth_frame>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket = assign_user_and_token(socket, params)

    form_source =
      case socket.assigns do
        %{user: user} ->
          Accounts.change_user_password(user)

        _ ->
          %{}
      end

    {:ok, assign_form(socket, form_source), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password reset successfully."))
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp assign_user_and_token(socket, %{"token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      assign(socket, user: user, token: token)
    else
      socket
      |> put_flash(:error, gettext("Reset password link is invalid or it has expired."))
      |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, %{} = source) do
    assign(socket, :form, to_form(source, as: "user"))
  end
end
