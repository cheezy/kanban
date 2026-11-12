defmodule KanbanWeb.UserAuth.SessionReissue do
  @moduledoc """
  How `KanbanWeb.UserAuth` reissues a session token and revokes the one it
  replaced (D425).

  Once a session token is 7 days old, the next request reissues it. The
  replaced token is not deleted in that request: the response may never reach
  the browser, and a parallel request may still carry it, so deleting it there
  could sign the user out. Instead `Kanban.Accounts.SessionReissue` links it
  to its successor and leaves it valid for at most an hour, and a replay of it
  in that hour is handed the same successor rather than a new token. The
  session remembers it as `:replaced_user_token`, and it is revoked, with its
  LiveView pages disconnected, by whichever comes first:

    * the first request that presents the successor (`confirm/2`), which
      proves the browser holds the new cookie;
    * sign-out (`revoke_on_log_out/1`), which revokes the whole family;
    * five minutes before the hour ends (`KanbanWeb.UserAuth.ReplacedSessionWorker`).

  A disconnected page reconnects with the browser's current cookie, so it
  stays signed in, unless the user has signed out.
  """

  import Plug.Conn

  alias Kanban.Accounts
  alias KanbanWeb.UserAuth
  alias KanbanWeb.UserAuth.LiveSessions
  alias KanbanWeb.UserAuth.ReplacedSessionWorker

  # How old a session token is before the next request reissues it. Lowering
  # it creates more tokens for active users; raising it above the 14-day
  # cookie age disables reissue altogether.
  @reissue_age_in_days 7
  @grace_in_seconds 60 * 60
  # The revocation job runs this long before the replaced token expires, so a
  # page still connected under it is moved to the successor before the token
  # stops working, even if the job waits behind a cleanup on its queue.
  @revocation_lead_in_seconds 5 * 60

  @doc "How long a replaced token stays valid, in seconds."
  def grace_in_seconds, do: @grace_in_seconds

  @doc """
  Reissues the session token `token`, verified for `user` at
  `token_inserted_at`, once it is older than the reissue age.
  """
  def maybe_reissue(conn, user, token, token_inserted_at) do
    token_age = DateTime.utc_now(:second) |> DateTime.diff(token_inserted_at, :day)

    if token_age >= @reissue_age_in_days do
      reissue(conn, user, token)
    else
      conn
    end
  end

  defp reissue(conn, user, token) do
    case Accounts.SessionReissue.reissue(user, token, @grace_in_seconds) do
      {:ok, successor, replaced_id} ->
        schedule_revocation(replaced_id)

        conn
        |> UserAuth.put_reissued_token(successor)
        |> put_session(:replaced_user_token, token)

      {:error, :not_found} ->
        conn
    end
  end

  defp schedule_revocation(nil), do: :ok

  defp schedule_revocation(replaced_id) do
    {:ok, _job} =
      ReplacedSessionWorker.schedule(replaced_id, @grace_in_seconds - @revocation_lead_in_seconds)

    :ok
  end

  @doc """
  Revokes the token the session remembers as replaced, now that a request
  has authenticated with `token`, its successor.
  """
  def confirm(conn, token) do
    case get_session(conn, :replaced_user_token) do
      nil ->
        conn

      ^token ->
        conn

      replaced_token ->
        # Only the replaced token goes; its successor is the one in use. The
        # cascade on replaced_by_id takes any token it had replaced itself.
        :ok = Accounts.delete_user_session_token(replaced_token)
        LiveSessions.disconnect_live_sessions([%{token: replaced_token}])
        delete_session(conn, :replaced_user_token)
    end
  end

  @doc """
  Revokes the family of the session's current token at sign-out: the token
  itself, every token it replaced and every token that replaced it, with
  their LiveView pages disconnected. The current token's own topic is
  disconnected by `KanbanWeb.UserAuth.log_out_user/1`.
  """
  def revoke_on_log_out(conn) do
    [get_session(conn, :user_token), get_session(conn, :replaced_user_token)]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(
      &(&1
        |> Accounts.SessionReissue.revoke_family()
        |> LiveSessions.disconnect_live_sessions())
    )
  end
end
