defmodule KanbanWeb.API.Agent.AgentSpecificInstructionsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Agent.AgentSpecificInstructions
  alias KanbanWeb.API.Agent.SetupDocs

  @base_url "https://stride.example.test"

  describe "instructions/1" do
    test "has an entry for every assistant, Pi included" do
      assert AgentSpecificInstructions.instructions(@base_url) |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 :aider,
                 :claude_code,
                 :cline,
                 :codex,
                 :copilot,
                 :cursor,
                 :gemini,
                 :generic,
                 :kimi,
                 :opencode,
                 :pi,
                 :windsurf
               ])
    end

    test "every entry has a description and at least one step" do
      for {name, entry} <- AgentSpecificInstructions.instructions(@base_url) do
        assert is_binary(entry.description), "#{name} has no description"
        assert entry |> Map.get(:steps, []) |> length() > 0, "#{name} has no steps"
      end
    end

    test "uses the given base URL" do
      instructions = AgentSpecificInstructions.instructions(@base_url)

      assert Enum.join(instructions.generic.steps, " ") =~ "#{@base_url}/api/agent/onboarding"
      assert Enum.join(instructions.aider.steps, " ") =~ "STRIDE_API_URL=#{@base_url}"
      assert instructions.claude_code.example_agents_md_section =~ @base_url
    end

    test "is the memory strategy's agent_specific_instructions" do
      assert SetupDocs.memory_strategy(@base_url).agent_specific_instructions ==
               AgentSpecificInstructions.instructions(@base_url)
    end
  end
end
