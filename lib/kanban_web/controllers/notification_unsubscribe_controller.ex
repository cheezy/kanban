defmodule KanbanWeb.NotificationUnsubscribeController do
  @moduledoc """
  Turns one category of notification email off from a signed email link,
  without logging in.

    * `show` (GET) — verifies the token and asks for confirmation. It never
      changes anything, because mail scanners prefetch links.
    * `update` (POST, CSRF-protected) — the confirmation form.
    * `one_click` (POST, no session or CSRF) — RFC 8058 one-click
      unsubscribe, called directly by mail providers.

  The `?token=` query parameter is the only credential. It names one user and
  one event type and can only turn that category's email off. Every failure —
  a tampered, expired or unknown token, or a deleted user — gets the same
  generic response, so a link never reveals whether an account exists, and
  the page never shows whose account it is.
  """

  use KanbanWeb, :controller

  alias Kanban.Notifications
  alias KanbanWeb.NotificationLabels
  alias KanbanWeb.UnsubscribeToken

  def show(conn, params) do
    conn = no_referrer(conn)

    case UnsubscribeToken.verify(params["token"]) do
      {:ok, %{event_type: event_type}} ->
        render(conn, :show,
          state: :confirm,
          category: NotificationLabels.category(event_type),
          token: params["token"]
        )

      {:error, _reason} ->
        render_invalid(conn)
    end
  end

  def update(conn, params) do
    conn = no_referrer(conn)

    case unsubscribe(params) do
      {:ok, event_type} ->
        render(conn, :show, state: :done, category: NotificationLabels.category(event_type))

      :error ->
        render_invalid(conn)
    end
  end

  def one_click(conn, %{"List-Unsubscribe" => "One-Click"} = params) do
    case unsubscribe(params) do
      {:ok, _event_type} -> send_resp(conn, :ok, "")
      :error -> send_resp(conn, :bad_request, "")
    end
  end

  def one_click(conn, _params), do: send_resp(conn, :bad_request, "")

  defp unsubscribe(params) do
    with {:ok, %{user_id: user_id, event_type: event_type}} <-
           UnsubscribeToken.verify(params["token"]),
         :ok <- Notifications.unsubscribe(user_id, event_type) do
      {:ok, event_type}
    else
      _error -> :error
    end
  end

  defp render_invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> render(:show, state: :invalid)
  end

  # These pages carry the token in their URL; never send it on in a Referer.
  defp no_referrer(conn), do: put_resp_header(conn, "referrer-policy", "no-referrer")
end
