defmodule KanbanWeb.API.AgentAttribution do
  @moduledoc """
  Resolves which agent an API write is attributed to (D137). This is the one
  resolution point shared by task creation (`created_by_agent`) and comments
  (`author_agent_name`) over both REST and MCP, so the two cannot drift.

  The order is:

    1. the token's `agent_model`, as `"ai_agent:<model>"`;
    2. the request's `agent_name`, when it is a usable name;
    3. the token's remembered `last_agent_name`, when it is a usable name;
    4. otherwise `nil`, meaning the write is unattributed.

  A usable name is whatever `Kanban.ApiTokens.usable_agent_name?/1` accepts: a
  valid UTF-8 string with no NUL, at least one visible character (whitespace
  and invisible format characters such as zero-width or bidi controls do not
  count), and not the `"Unknown"` claim and complete fallback.

  The result is display attribution only. Authorship always belongs to the
  token's user and is never taken from the request.
  """

  alias Kanban.ApiTokens

  @doc """
  The agent name a write made with `api_token` and the request's
  `agent_name` is attributed to, or `nil`.
  """
  @spec resolve(map(), term()) :: String.t() | nil
  def resolve(api_token, agent_name) do
    cond do
      api_token.agent_model -> "ai_agent:#{api_token.agent_model}"
      ApiTokens.usable_agent_name?(agent_name) -> agent_name
      ApiTokens.usable_agent_name?(api_token.last_agent_name) -> api_token.last_agent_name
      true -> nil
    end
  end
end
