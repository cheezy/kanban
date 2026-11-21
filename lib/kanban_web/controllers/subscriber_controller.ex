defmodule KanbanWeb.SubscriberController do
  @moduledoc """
  The release announcement list's public routes (W2905), all under
  `/releases`:

    * `create` (POST, CSRF-protected) — the signup form on `/changelog`.
      Every accepted signup, new address or not, redirects back with the
      same message, so the response never reveals whether an address is on
      the list. There is no GET route, so a GET subscribes no one.
    * `confirm_show` (GET) — verifies the emailed confirmation token and
      asks for confirmation. It changes nothing, because mail scanners
      prefetch links, so a scanner can never confirm an address.
    * `confirm` (POST, CSRF-protected) — activates the subscriber.
    * `unsubscribe_show` (GET) — verifies the unsubscribe token and asks for
      confirmation.
    * `one_click_show` (GET) — a browser opening the one-click URL is sent
      on to `unsubscribe_show` with the same query, so the prompt's form,
      which posts back to its own URL, reaches `unsubscribe`.
    * `unsubscribe` (POST, CSRF-protected) — deletes the subscriber.
    * `one_click` (POST, no session or CSRF) — RFC 8058 one-click
      unsubscribe, called directly by mail providers. It acts only when the
      `List-Unsubscribe=One-Click` marker is in the request body, as RFC 8058
      requires, never when it is only in the URL.

  The `?token=` query parameter is the only credential. The prompt pages
  never write it into their markup: their forms have no action and post
  back to the page's own URL. Every bad token — an unknown, expired or used
  one — gets the same generic page, and no page ever shows the address.
  Every response is noindex and sends no Referer.
  """

  use KanbanWeb, :controller

  plug KanbanWeb.Plugs.PutNoindex
  plug :no_referrer

  alias Kanban.Subscribers
  alias KanbanWeb.ReleaseSignupForm

  def create(conn, params) do
    result =
      params
      |> signup_email()
      |> Subscribers.subscribe(
        ip: conn.remote_ip,
        locale: Gettext.get_locale(KanbanWeb.Gettext),
        consent_text: ReleaseSignupForm.consent_text()
      )

    conn
    |> put_signup_flash(result)
    |> redirect(to: ~p"/changelog")
  end

  def confirm_show(conn, params) do
    if Subscribers.confirm_token_valid?(params["token"]),
      do: render_state(conn, :confirm_prompt),
      else: render_invalid(conn)
  end

  def confirm(conn, params) do
    case Subscribers.confirm(params["token"]) do
      {:ok, _subscriber} -> render_state(conn, :confirmed)
      :error -> render_invalid(conn)
    end
  end

  def unsubscribe_show(conn, params) do
    if Subscribers.unsubscribe_token_valid?(params["token"]),
      do: render_state(conn, :unsubscribe_prompt),
      else: render_invalid(conn)
  end

  def unsubscribe(conn, params) do
    case Subscribers.unsubscribe(params["token"]) do
      :ok -> render_state(conn, :unsubscribed)
      :error -> render_invalid(conn)
    end
  end

  def one_click_show(conn, _params),
    do: redirect(conn, to: ~p"/releases/unsubscribe?#{conn.query_params}")

  def one_click(%{body_params: %{"List-Unsubscribe" => "One-Click"}} = conn, params) do
    case Subscribers.unsubscribe(params["token"]) do
      :ok -> send_resp(conn, :ok, "")
      :error -> send_resp(conn, :bad_request, "")
    end
  end

  def one_click(conn, _params), do: send_resp(conn, :bad_request, "")

  defp signup_email(%{"subscriber" => %{"email" => email}}), do: email
  defp signup_email(_params), do: nil

  defp put_signup_flash(conn, :ok) do
    put_flash(
      conn,
      :info,
      gettext(
        "Thanks! Check your inbox: if this address is not on the list yet, we have sent it a link to confirm your subscription."
      )
    )
  end

  defp put_signup_flash(conn, {:error, :rate_limited}),
    do: put_flash(conn, :error, gettext("Too many signups from your network. Try again later."))

  defp put_signup_flash(conn, {:error, %Ecto.Changeset{}}),
    do: put_flash(conn, :error, gettext("Enter a valid email address to subscribe."))

  defp render_state(conn, state) do
    render(conn, :show, state: state, page_title: page_title(state))
  end

  defp render_invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> render_state(:invalid)
  end

  defp page_title(state) when state in [:confirm_prompt, :confirmed],
    do: gettext("Confirm your subscription")

  defp page_title(state) when state in [:unsubscribe_prompt, :unsubscribed],
    do: gettext("Unsubscribe from release announcements")

  defp page_title(:invalid), do: gettext("This link is no longer valid")

  # These pages carry the token in their URL; never send it on in a Referer.
  defp no_referrer(conn, _opts), do: put_resp_header(conn, "referrer-policy", "no-referrer")
end
