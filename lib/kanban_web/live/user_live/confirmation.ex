defmodule KanbanWeb.UserLive.Confirmation do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias Kanban.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame quote_key={:magic}>
      <:footer_switch>
        <.link
          navigate={~p"/users/log-in"}
          style="color: var(--ink-2); text-decoration: none;"
        >
          <span aria-hidden="true">←</span> {gettext("Back to sign in")}
        </.link>
      </:footer_switch>

      <div style="display: flex; flex-direction: column; align-items: center; text-align: center;">
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
          {if @confirmed,
            do: gettext("Account confirmed"),
            else: gettext("Confirming your account…")}
        </h1>

        <p style="margin: 10px 0 0; font-size: 13.5px; color: var(--ink-3); max-width: 360px; text-wrap: pretty;">
          {if @confirmed,
            do: gettext("Your account has been confirmed successfully. You can now sign in."),
            else: gettext("Hold tight — this will only take a moment.")}
        </p>

        <%= if @confirmed do %>
          <div style="margin-top: 28px; width: 100%;">
            <.primary_full_button>
              <.link navigate={~p"/users/log-in"} style="color: white; text-decoration: none;">
                {gettext("Sign in")} <span aria-hidden="true">→</span>
              </.link>
            </.primary_full_button>
          </div>
        <% else %>
          <div style="margin-top: 28px; padding: 12px 16px; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; display: flex; align-items: center; gap: 12px; width: 100%;">
            <span style="width: 16px; height: 16px; border-radius: 50%; border: 2px solid var(--surface-sunken); border-top-color: var(--stride-orange); animation: authspin 0.8s linear infinite; flex-shrink: 0;">
            </span>
            <div style="flex: 1; text-align: left;">
              <div style="font-size: 12.5px; color: var(--ink); font-weight: 500;">
                {gettext("Verifying your confirmation link…")}
              </div>
              <div style="font-family: var(--font-mono); font-size: 10.5px; color: var(--ink-3); letter-spacing: -0.01em;">
                {gettext("this tab will sign you in automatically")}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </.auth_frame>
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
