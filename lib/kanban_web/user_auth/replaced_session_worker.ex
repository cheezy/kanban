defmodule KanbanWeb.UserAuth.ReplacedSessionWorker do
  @moduledoc """
  Revokes a replaced session token shortly before its grace window ends
  (D425). It runs on the shared `:maintenance` queue, five minutes early, so a
  wait behind a cleanup job there does not outlast the token.

  A tab whose LiveView connected under the replaced token keeps that token in
  its connect-time session. Disconnecting it here, once the token is deleted,
  makes it reconnect with the browser's current cookie, the successor, so it
  stays signed in instead of being sent to the log-in page on its next live
  navigation. Already revoked (by the browser presenting the successor, or by
  sign-out) means there is nothing to do.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Kanban.Accounts.SessionReissue

  @doc "Schedules the revocation of the replaced token `token_id` in `seconds`."
  def schedule(token_id, seconds) do
    %{"token_id" => token_id}
    |> new(schedule_in: seconds)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"token_id" => token_id}}) do
    case SessionReissue.revoke_replaced(token_id) do
      nil -> :ok
      token -> KanbanWeb.UserAuth.LiveSessions.disconnect_live_sessions([%{token: token}])
    end
  end
end
