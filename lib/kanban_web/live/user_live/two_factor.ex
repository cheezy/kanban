defmodule KanbanWeb.UserLive.TwoFactor do
  @moduledoc """
  The second step of signing in for a user with two-factor turned on (W2242).

  Reached only with the pending-login marker the password step stores
  (`KanbanWeb.TwoFactorPending`); without a valid one it sends the visitor
  back to the log-in page. The form asks for a code from the authenticator
  app, or a recovery code, and submits it to `POST /users/two-factor`
  (`UserSessionController.verify_two_factor/2`), which logs the user in.
  Mounting has no side effects, so a refresh or a second tab only re-renders.
  """

  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias KanbanWeb.TwoFactorPending

  @input_style "padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: var(--font-mono); letter-spacing: 0.08em;"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input_style, @input_style)

    ~H"""
    <.auth_frame flash={@flash}>
      <:footer_switch>
        <.link
          navigate={~p"/users/log-in"}
          style="color: var(--ink); font-weight: 500; text-decoration: none;"
        >
          <span aria-hidden="true">←</span> {gettext("Back to sign in")}
        </.link>
      </:footer_switch>

      <div>
        <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
          {gettext("Two-factor authentication")}
        </h1>
        <p id="two-factor-hint" style="margin: 8px 0 0; font-size: 13.5px; color: var(--ink-3);">
          {hint(@mode)}
        </p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="two_factor_form"
        action={~p"/users/two-factor"}
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
        style="margin-top: 28px; display: flex; flex-direction: column; gap: 12px;"
      >
        <input type="hidden" name={f[:mode].name} value={mode_value(@mode)} />

        <label style="display: flex; flex-direction: column; gap: 5px;">
          <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
            {code_label(@mode)}
          </span>
          <input
            type="text"
            name={f[:code].name}
            id={f[:code].id}
            value=""
            inputmode={if @mode == :totp, do: "numeric", else: "text"}
            autocomplete="one-time-code"
            autocapitalize="off"
            spellcheck="false"
            maxlength="32"
            required
            phx-mounted={JS.focus()}
            style={@input_style}
          />
        </label>

        <div style="margin-top: 4px;">
          <.primary_full_button kbd="↵" type="submit">{gettext("Verify")}</.primary_full_button>
        </div>
      </.form>

      <p style="margin: 14px 0 0; text-align: center;">
        <button
          type="button"
          id="two-factor-toggle-mode"
          phx-click="toggle_mode"
          style="background: none; border: 0; padding: 0; cursor: pointer; font-size: 12px; color: var(--ink-3); font-family: inherit;"
        >
          {toggle_label(@mode)}
        </button>
      </p>
    </.auth_frame>
    """
  end

  @impl true
  def mount(params, session, socket) do
    case TwoFactorPending.from_session(session) do
      {:ok, _pending} ->
        {:ok, socket |> assign(trigger_submit: false) |> assign_mode(mode_param(params))}

      {:error, :expired} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Your sign-in attempt expired. Please sign in again."))
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("toggle_mode", _params, socket) do
    {:noreply, assign_mode(socket, other_mode(socket.assigns.mode))}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  defp assign_mode(socket, mode) do
    form = to_form(%{"code" => "", "mode" => mode_value(mode)}, as: "two_factor")
    assign(socket, mode: mode, form: form)
  end

  defp mode_param(%{"mode" => "recovery"}), do: :recovery
  defp mode_param(_params), do: :totp

  defp other_mode(:totp), do: :recovery
  defp other_mode(:recovery), do: :totp

  defp mode_value(:totp), do: "totp"
  defp mode_value(:recovery), do: "recovery"

  defp hint(:totp), do: gettext("Enter the 6-digit code from your authenticator app.")

  defp hint(:recovery) do
    gettext("Enter one of the recovery codes you saved when you turned on two-factor.")
  end

  defp code_label(:totp), do: gettext("Authentication code")
  defp code_label(:recovery), do: gettext("Recovery code")

  defp toggle_label(:totp), do: gettext("Use a recovery code instead")
  defp toggle_label(:recovery), do: gettext("Use your authenticator app instead")
end
