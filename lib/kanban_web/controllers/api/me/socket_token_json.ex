defmodule KanbanWeb.API.Me.SocketTokenJSON do
  @moduledoc """
  JSON rendering for `POST /api/me/socket_token` (W2765,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7).

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). `priv/openapi/stride-api.json` documents
  the same keys as `MeSocketToken`.
  """

  alias KanbanWeb.SocketToken

  @doc "A new socket token, when it expires, and how many seconds it is valid."
  def show(%{token: token, expires_at: %DateTime{} = expires_at}) do
    %{
      data: %{
        token: token,
        expires_at: DateTime.to_iso8601(expires_at),
        expires_in: SocketToken.max_age()
      }
    }
  end
end
