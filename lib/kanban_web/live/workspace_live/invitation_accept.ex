defmodule KanbanWeb.WorkspaceLive.InvitationAccept do
  @moduledoc """
  The invitation link page, `/invitations/:token` (W2219).

  It lives in the `:current_user` live session, which works with or without a
  signed-in user, because an invitee may not have an account yet. The page
  has four states, decided by `Kanban.Workspaces.Invitations.preview/2`:

    * `:sign_in` — a valid link and nobody signed in. Nothing about the
      invitation is shown (not the workspace, the board or the invited
      address); the visitor can create an account from the link, which carries
      the token through registration, or sign in and open the link again.
    * `:ready` — a signed-in user whose email matches. The page names what
      they are joining and offers an Accept button. Nothing is accepted on
      mount; only the button accepts, and acceptance checks everything again.
    * `:invalid` — every other state, with one generic message: unknown,
      expired, revoked or used links, another account's invitation, and an
      invitee in another Organization. A signed-in user also sees which
      account they are using, never the invited address.
    * `:full` — the free board is at its member cap.
  """
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias Kanban.Workspaces.Invitations
  alias KanbanWeb.WorkspaceLive.InvitationMessages

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    user = current_user(socket)

    {state, details} =
      case Invitations.preview(token, user) do
        {:ok, :sign_in_required} -> {:sign_in, nil}
        {:ok, details} -> {:ready, details}
        {:error, :invalid} -> {:invalid, nil}
      end

    {:ok,
     socket
     |> assign(:page_title, gettext("Invitation"))
     |> assign(:token, token)
     |> assign(:state, state)
     |> assign(:details, details)
     |> assign(:user, user)}
  end

  @impl true
  def handle_event("accept", _params, %{assigns: %{state: :ready, user: %{} = user}} = socket) do
    {:noreply, socket.assigns.token |> Invitations.accept(user) |> respond_to_accept(socket)}
  end

  def handle_event("accept", _params, socket), do: {:noreply, socket}

  defp respond_to_accept({:ok, result} = accepted, socket) do
    {kind, message} = InvitationMessages.flash(accepted)

    socket
    |> put_flash(kind, message)
    |> push_navigate(to: destination(result))
  end

  defp respond_to_accept({:error, :member_cap_reached}, socket),
    do: assign(socket, :state, :full)

  defp respond_to_accept({:error, _reason}, socket), do: assign(socket, :state, :invalid)

  defp destination(%{board: %{id: id}}), do: ~p"/boards/#{id}"
  defp destination(_result), do: ~p"/boards"

  defp current_user(%{assigns: %{current_scope: %{user: %{} = user}}}), do: user
  defp current_user(_socket), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame flash={@flash}>
      <:footer_switch>
        <.link navigate={~p"/"} style="color: var(--ink-2); text-decoration: none;">
          <span aria-hidden="true">←</span> {gettext("Return to Stride")}
        </.link>
      </:footer_switch>

      <div id="invitation" data-state={@state}>
        <h1 style="margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15; color: var(--ink);">
          {heading(@state)}
        </h1>

        <%= case @state do %>
          <% :sign_in -> %>
            <p style={text_style()}>
              {gettext(
                "Create an account with the email address this invitation was sent to, or sign in if you already have one and then open this link again."
              )}
            </p>
            <div style="margin-top: 20px; display: flex; flex-direction: column; gap: 10px;">
              <%!-- A link styled as the frame's ink button: dark on light and light
                    on dark, labelled with var(--surface) in both themes. --%>
              <.link
                id="invitation-register"
                navigate={~p"/users/register?#{[invitation_token: @token]}"}
                style="height: 40px; border-radius: 6px; background: var(--ink); color: var(--surface); font-size: 13.5px; font-weight: 500; display: flex; align-items: center; justify-content: center; text-decoration: none;"
              >
                {gettext("Create account")}
              </.link>
              <.link
                id="invitation-sign-in"
                navigate={~p"/users/log-in"}
                style="font-size: 13px; color: var(--ink); text-align: center; text-decoration: underline;"
              >
                {gettext("Sign in")}
              </.link>
            </div>
          <% :ready -> %>
            <p id="invitation-target" style={text_style()}>
              {target_text(@details)}
            </p>
            <div style="margin-top: 20px;">
              <.primary_full_button
                id="accept-invitation"
                type="button"
                phx-click="accept"
                phx-disable-with={gettext("Joining...")}
              >
                {gettext("Accept invitation")}
              </.primary_full_button>
            </div>
          <% :full -> %>
            <p id="invitation-full" style={text_style()}>{InvitationMessages.board_full()}</p>
          <% :invalid -> %>
            <p id="invitation-invalid" style={text_style()}>{InvitationMessages.invalid()}</p>
            <p :if={@user} id="invitation-account" style={text_style()}>
              {gettext("You're signed in as %{email}.", email: @user.email)}
              <.link
                href={~p"/users/log-out"}
                method="delete"
                style="color: var(--ink); text-decoration: underline;"
              >
                {gettext("Log out")}
              </.link>
            </p>
        <% end %>
      </div>
    </.auth_frame>
    """
  end

  defp text_style,
    do: "margin: 12px 0 0; font-size: 13.5px; color: var(--ink-2); line-height: 1.55;"

  defp heading(:ready), do: gettext("You're invited")
  defp heading(:sign_in), do: gettext("You're invited")
  defp heading(:full), do: gettext("This board is full")
  defp heading(:invalid), do: gettext("Invitation unavailable")

  defp target_text(%{target: :board, board_name: board}) when is_binary(board),
    do: gettext("Join the board %{board}.", board: board)

  defp target_text(%{workspace_name: workspace, organization_name: org, board_name: board})
       when is_binary(board),
       do:
         gettext("Join the workspace %{workspace} in %{organization}, with access to %{board}.",
           workspace: workspace,
           organization: org || "",
           board: board
         )

  defp target_text(%{workspace_name: workspace, organization_name: org}),
    do:
      gettext("Join the workspace %{workspace} in %{organization}.",
        workspace: workspace,
        organization: org || ""
      )
end
