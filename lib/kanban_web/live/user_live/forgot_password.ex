defmodule KanbanWeb.UserLive.ForgotPassword do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias Kanban.Accounts
  alias Kanban.RateLimit

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame flash={@flash}>
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
          {gettext("Reset your password")}
        </h1>
        <p style="margin: 8px 0 0; font-size: 13.5px; color: var(--ink-3); text-wrap: pretty;">
          {gettext("We'll email a one-time link. The link expires in 15 minutes.")}
        </p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="reset_password_form"
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
            placeholder={gettext("Email")}
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
            style="padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid var(--line-strong); font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
          />
        </label>

        <.primary_full_button kbd="↵" type="submit">
          {gettext("Send reset link")}
        </.primary_full_button>
      </.form>

      <div style="margin-top: 28px; padding: 14px; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; display: flex; align-items: flex-start; gap: 10px;">
        <span style="width: 24px; height: 24px; border-radius: 6px; background: var(--stride-violet-soft); color: var(--stride-violet-ink); display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0;">
          <.icon name="hero-cpu-chip" class="w-3 h-3" />
        </span>
        <div style="font-size: 12px; color: var(--ink-2); line-height: 1.55; text-wrap: pretty;">
          <strong style="color: var(--ink); font-weight: 600;">{gettext("For agents:")}</strong>
          {gettext("resetting your operator password does")}
          <em>{gettext("not")}</em>
          {gettext("rotate API tokens. Rotate from")}
          <span style="font-family: var(--font-mono); color: var(--ink);">
            {gettext("Board → Tokens")}
          </span>
          {gettext("if you suspect a key is compromised.")}
        </div>
      </div>
    </.auth_frame>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:client_ip, KanbanWeb.ClientIp.from_session_or_socket(session, socket))
     |> assign(:form, to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    # Keyed on (IP, email) and checked BEFORE the existence lookup, so the limit
    # applies identically whether or not the account exists — preserving the
    # non-enumeration property of the neutral flash below.
    case RateLimit.check(:reset, ip: socket.assigns.client_ip, identity: email) do
      {:error, {:rate_limited, _}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Too many requests. Please wait a few minutes and try again.")
         )
         |> redirect(to: ~p"/")}

      :ok ->
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
end
