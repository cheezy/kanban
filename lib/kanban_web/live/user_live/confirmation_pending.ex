defmodule KanbanWeb.UserLive.ConfirmationPending do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias Kanban.Accounts

  @resend_cooldown_seconds 60
  @max_email_length 160
  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame flash={@flash}>
      <:footer_switch>
        <.link navigate={~p"/"} style="color: var(--ink); font-weight: 500; text-decoration: none;">
          <span aria-hidden="true">←</span> {gettext("Return to Stride")}
        </.link>
      </:footer_switch>

      <div
        :if={@email}
        style="display: flex; flex-direction: column; align-items: center; text-align: center;"
      >
        <div style="width: 72px; height: 72px; border-radius: 16px; background: linear-gradient(135deg, var(--stride-orange-soft) 0%, var(--stride-violet-soft) 100%); display: inline-flex; align-items: center; justify-content: center; color: var(--stride-orange-ink); box-shadow: inset 0 0 0 1px var(--line);">
          <svg
            width="34"
            height="34"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            xmlns="http://www.w3.org/2000/svg"
          >
            <rect x="3" y="6" width="18" height="13" rx="2" />
            <path d="M3 8l9 6 9-6" />
          </svg>
        </div>

        <h1 style="margin: 20px 0 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
          {gettext("Check your email")}
        </h1>

        <p style="margin: 10px 0 0; font-size: 13.5px; color: var(--ink-3); max-width: 360px; text-wrap: pretty;">
          {gettext(
            "We sent a confirmation link to %{email}. You won't be able to sign in until your account is confirmed.",
            email: @email
          )}
        </p>

        <p style="margin: 8px 0 0; font-family: var(--font-mono); font-size: 10.5px; color: var(--ink-3); letter-spacing: -0.01em;">
          {gettext("Didn't get it? Check your spam folder or resend below.")}
        </p>

        <div style="margin-top: 28px; width: 100%;">
          <.primary_full_button
            type="button"
            phx-click="resend"
            phx-disable-with={gettext("Sending…")}
          >
            {gettext("Resend confirmation email")}
          </.primary_full_button>
        </div>
      </div>

      <div :if={is_nil(@email)}>
        <div>
          <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
            {gettext("Resend confirmation email")}
          </h1>
          <p style="margin: 8px 0 0; font-size: 13.5px; color: var(--ink-3); text-wrap: pretty;">
            {gettext("Enter the email you signed up with and we'll send a new confirmation link.")}
          </p>
        </div>

        <.form
          :let={f}
          for={@form}
          id="resend_confirmation_form"
          phx-submit="send_email"
          style="margin-top: 28px; display: flex; flex-direction: column; gap: 12px;"
        >
          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Email")}
            </span>
            <input
              type="email"
              name={f[:email].name}
              id={f[:email].id}
              value={Phoenix.HTML.Form.normalize_value("email", f[:email].value)}
              autocomplete="username"
              required
              maxlength="160"
              phx-mounted={JS.focus()}
              style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
            />
          </label>

          <.primary_full_button kbd="↵" type="submit" phx-disable-with={gettext("Sending…")}>
            {gettext("Send confirmation link")}
          </.primary_full_button>
        </.form>
      </div>
    </.auth_frame>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    case validate_email_param(params) do
      {:ok, email} ->
        {:ok, assign(socket, email: email, last_resend_at: nil)}

      :error ->
        {:ok, assign(socket, email: nil, last_resend_at: nil, form: to_form(%{}, as: "user"))}
    end
  end

  @impl true
  def handle_event("resend", _params, socket) do
    if rate_limited?(socket) do
      {:noreply,
       put_flash(socket, :info, gettext("Please wait a moment before requesting another email."))}
    else
      {:noreply, deliver_and_flash(socket, socket.assigns.email)}
    end
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    cond do
      rate_limited?(socket) ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Please wait a moment before requesting another email.")
         )}

      not valid_email?(email) ->
        {:noreply, put_flash(socket, :error, gettext("Enter a valid email address."))}

      true ->
        {:noreply, socket |> deliver_and_flash(email) |> assign(:email, email)}
    end
  end

  # Deliver only when the account exists and is unconfirmed; the flash is
  # identical either way so the endpoint can't be used to enumerate emails.
  defp deliver_and_flash(socket, email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
    end

    socket
    |> assign(:last_resend_at, System.system_time(:second))
    |> put_flash(
      :info,
      gettext(
        "If your email is in our system and the account isn't confirmed yet, you will receive a new confirmation link shortly."
      )
    )
  end

  defp rate_limited?(socket) do
    case socket.assigns.last_resend_at do
      nil -> false
      last -> System.system_time(:second) - last < @resend_cooldown_seconds
    end
  end

  defp validate_email_param(%{"email" => email}) do
    if valid_email?(email), do: {:ok, email}, else: :error
  end

  defp validate_email_param(_params), do: :error

  defp valid_email?(email) when is_binary(email) and byte_size(email) <= @max_email_length do
    Regex.match?(@email_format, email)
  end

  defp valid_email?(_email), do: false
end
