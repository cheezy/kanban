defmodule KanbanWeb.OnboardingPluginsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.OnboardingPlugins
  alias KanbanWeb.OnboardingPlugins.Agent

  describe "agents/0" do
    test "returns exactly six agents in the documented order" do
      keys = Enum.map(OnboardingPlugins.agents(), & &1.key)
      assert keys == ~w(claude_code copilot gemini codex opencode pi)
    end

    test "labels match the documented display order" do
      labels = Enum.map(OnboardingPlugins.agents(), & &1.label)
      assert labels == ["Claude Code", "Copilot", "Gemini", "Codex", "OpenCode", "Pi"]
    end

    test "every entry is an Agent struct with a non-empty workflow command and URL" do
      for agent <- OnboardingPlugins.agents() do
        assert %Agent{} = agent
        assert is_binary(agent.workflow_command) and agent.workflow_command != ""
        assert is_binary(agent.workflow_url) and agent.workflow_url != ""
      end
    end

    test "every workflow URL is a trusted https github link" do
      for agent <- OnboardingPlugins.agents() do
        assert String.starts_with?(agent.workflow_url, "https://github.com/cheezy/"),
               "#{agent.key} workflow_url is not a trusted github link: #{agent.workflow_url}"
      end
    end

    test "only Claude Code uses a marketplace; every other agent does not" do
      for agent <- OnboardingPlugins.agents() do
        expected = agent.key == "claude_code"

        assert agent.uses_marketplace == expected,
               "#{agent.key} uses_marketplace should be #{expected}"
      end
    end

    test "Pi is flagged as not using a marketplace" do
      pi = OnboardingPlugins.get("pi")
      assert pi.uses_marketplace == false
    end

    test "the five agents with an ideation port have a non-empty command and https github URL" do
      for agent <- OnboardingPlugins.agents(), agent.key != "pi" do
        assert is_binary(agent.ideation_command) and agent.ideation_command != "",
               "#{agent.key} is missing an ideation command"

        assert String.starts_with?(agent.ideation_url, "https://github.com/cheezy/"),
               "#{agent.key} ideation_url is not a trusted github link: #{agent.ideation_url}"
      end
    end

    test "Pi has no ideation port (nil command and URL) with a note explaining the gap" do
      pi = OnboardingPlugins.get("pi")
      assert pi.ideation_command == nil
      assert pi.ideation_url == nil
      assert pi.note =~ "ideation"
    end

    test "every agent has a non-empty note" do
      for agent <- OnboardingPlugins.agents() do
        assert is_binary(agent.note) and agent.note != ""
      end
    end
  end

  describe "get/1" do
    test "returns the correct entry for each known key" do
      for agent <- OnboardingPlugins.agents() do
        assert OnboardingPlugins.get(agent.key) == agent
      end
    end

    test "returns nil for an unknown key" do
      assert OnboardingPlugins.get("does-not-exist") == nil
    end

    test "returns nil for a non-string key rather than raising" do
      assert OnboardingPlugins.get(nil) == nil
      assert OnboardingPlugins.get(:claude_code) == nil
      assert OnboardingPlugins.get(42) == nil
    end
  end
end
