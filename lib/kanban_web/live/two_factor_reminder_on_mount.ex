defmodule KanbanWeb.TwoFactorReminderOnMount do
  @moduledoc """
  Shows the two-factor setup reminder on the page a user lands on right after
  signing in, and handles its "Not now" button on every authenticated page.

  Whether the reminder is due is decided once, at password sign-in, by
  `KanbanWeb.UserSessionController`, which puts a `:two_factor_reminder` flash
  before the redirect. This hook runs after `KanbanWeb.NotificationsOnMount` in
  the authenticated, sudo and admin `live_session`s and copies that flash into
  `current_scope.two_factor_reminder`, which `KanbanWeb.Layouts.app/1` reads to
  render the card. No page queries two-factor status itself.

  Live navigation carries no flash, so the card belongs to the landing page and
  is gone on the next one. Once connected, the hook attaches a `handle_event`
  hook that handles and halts `"dismiss_two_factor_reminder"`, so no LiveView
  needs its own clause. The dismissal is recorded for `current_scope.user`,
  never for anything in the event params.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, clear_flash: 2, connected?: 1]

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User

  @flash_key :two_factor_reminder
  @dismiss_event "dismiss_two_factor_reminder"

  def on_mount(:default, _params, _session, socket) do
    if reminder_flashed?(socket) do
      {:cont, socket |> put_flag(true) |> maybe_attach_hook()}
    else
      {:cont, socket}
    end
  end

  @doc false
  def handle_reminder_event(@dismiss_event, _params, socket) do
    %Scope{user: %User{} = user, two_factor_reminder: showing?} = socket.assigns.current_scope

    # A second click (or a second tab's stale button) finds the card already
    # gone and writes nothing.
    if showing?, do: {:ok, _user} = Accounts.dismiss_two_factor_reminder(user)

    {:halt, socket |> put_flag(false) |> clear_flash(@flash_key)}
  end

  def handle_reminder_event(_event, _params, socket), do: {:cont, socket}

  defp reminder_flashed?(socket) do
    match?(%Scope{user: %User{}}, socket.assigns[:current_scope]) and
      Phoenix.Flash.get(socket.assigns[:flash] || %{}, @flash_key) == true
  end

  # The disconnected render never receives events, so the hook is only needed
  # once connected.
  defp maybe_attach_hook(socket) do
    if connected?(socket) do
      attach_hook(
        socket,
        :two_factor_reminder,
        :handle_event,
        &__MODULE__.handle_reminder_event/3
      )
    else
      socket
    end
  end

  defp put_flag(socket, value) do
    scope = %{socket.assigns.current_scope | two_factor_reminder: value}
    assign(socket, :current_scope, scope)
  end
end
