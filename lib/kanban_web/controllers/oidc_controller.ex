defmodule KanbanWeb.OIDCController do
  use KanbanWeb, :controller

  alias Kanban.Accounts
  alias Kanban.OIDC
  alias KanbanWeb.UserAuth

  require Logger

  def request(conn, _params) do
    if OIDC.enabled?() do
      start_oidc_request(conn)
    else
      redirect_oidc_unavailable(conn)
    end
  end

  def callback(conn, params) do
    session_params = get_session(conn, OIDC.session_key())
    conn = delete_session(conn, OIDC.session_key())

    cond do
      not OIDC.enabled?() ->
        redirect_oidc_unavailable(conn)

      is_nil(session_params) ->
        redirect_oidc_failure(conn, :expired)

      true ->
        complete_oidc_callback(conn, params, session_params)
    end
  end

  defp start_oidc_request(conn) do
    callback_url = callback_url(conn)

    case OIDC.authorize_url(callback_url) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(OIDC.session_key(), session_params)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("OIDC authorization failed: #{inspect(reason)}")
        redirect_oidc_failure(conn, :unavailable)
    end
  end

  defp complete_oidc_callback(conn, params, session_params) do
    case OIDC.callback(params, session_params, callback_url(conn)) do
      {:ok, %{user: claims}} ->
        log_in_oidc_user(conn, claims)

      {:error, reason} ->
        Logger.warning("OIDC callback failed: #{inspect(reason)}")
        redirect_oidc_failure(conn, :failed)
    end
  end

  defp log_in_oidc_user(conn, claims) do
    case claims |> OIDC.provisioning_attrs() |> Accounts.authenticate_oidc() do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Signed in with %{provider}.", provider: OIDC.display_name()))
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        Logger.warning("OIDC user provisioning failed: #{inspect(reason)}")
        redirect_oidc_failure(conn, :provisioning_failed)
    end
  end

  defp redirect_oidc_unavailable(conn) do
    redirect_oidc_failure(conn, :not_configured)
  end

  defp redirect_oidc_failure(conn, reason) do
    conn
    |> put_flash(:error, oidc_error_message(reason))
    |> redirect(to: ~p"/users/log-in")
  end

  defp oidc_error_message(:expired),
    do: gettext("Single sign-on session expired. Please try again.")

  defp oidc_error_message(:unavailable),
    do: gettext("Single sign-on is not available right now.")

  defp oidc_error_message(:failed),
    do: gettext("Single sign-on failed. Please try again.")

  defp oidc_error_message(:provisioning_failed),
    do: gettext("Single sign-on could not create or update your account.")

  defp oidc_error_message(:not_configured),
    do: gettext("Single sign-on is not configured.")

  defp callback_url(conn), do: url(conn, ~p"/users/sso/callback")
end
