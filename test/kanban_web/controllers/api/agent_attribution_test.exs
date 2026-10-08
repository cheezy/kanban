defmodule KanbanWeb.API.AgentAttributionTest do
  use ExUnit.Case, async: true

  alias Kanban.ApiTokens.ApiToken
  alias KanbanWeb.API.AgentAttribution

  defp token(attrs \\ %{}),
    do: struct(ApiToken, Map.merge(%{agent_model: nil, last_agent_name: nil}, attrs))

  describe "resolve/2 (D137 order)" do
    test "the token's agent_model wins, prefixed ai_agent:" do
      api_token = token(%{agent_model: "claude-x", last_agent_name: "Remembered"})
      assert AgentAttribution.resolve(api_token, "Param") == "ai_agent:claude-x"
    end

    test "then a usable agent_name" do
      api_token = token(%{last_agent_name: "Remembered"})
      assert AgentAttribution.resolve(api_token, "Param") == "Param"
    end

    test "then the token's usable last_agent_name" do
      api_token = token(%{last_agent_name: "Remembered"})

      for unusable <- [nil, "", "   ", "Unknown", 42] do
        assert AgentAttribution.resolve(api_token, unusable) == "Remembered",
               "agent_name #{inspect(unusable)} should fall through"
      end
    end

    test "otherwise nil" do
      assert AgentAttribution.resolve(token(), nil) == nil
      api_token = token(%{last_agent_name: "Unknown"})
      assert AgentAttribution.resolve(api_token, "") == nil
    end
  end
end
