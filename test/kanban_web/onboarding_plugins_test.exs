defmodule KanbanWeb.OnboardingPluginsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Integrations
  alias KanbanWeb.OnboardingPlugins
  alias KanbanWeb.OnboardingPlugins.Agent

  @locales ~w(de en es fr ja pt zh)

  # What the picker shows for each agent, block by block. Every command is
  # one of the install steps on /integrations (or two of them joined), which
  # test/kanban_web/integrations_test.exs checks against the plugin READMEs.
  @expected_commands %{
    "claude_code" => [
      "/plugin marketplace add cheezy/stride-marketplace\n/plugin install stride@stride-marketplace"
    ],
    "copilot" => [
      "copilot plugin marketplace add cheezy/stride-copilot-marketplace\ncopilot plugin install stride-copilot"
    ],
    "gemini" => ["gemini extensions install https://github.com/cheezy/stride-gemini"],
    "codex" => [
      "codex plugin marketplace add cheezy/stride-codex-marketplace\ncodex plugin install stride-codex"
    ],
    "opencode" => [
      ~s({\n  "plugin": ["github:cheezy/stride-opencode"]\n}),
      "# Clone once somewhere\ngit clone https://github.com/cheezy/stride-opencode.git /tmp/stride-opencode"
    ],
    "pi" => [
      "curl -fsSL https://raw.githubusercontent.com/cheezy/stride-pi/main/install.sh | bash"
    ]
  }

  defp integration_commands(slug) do
    {:ok, runtime} = Integrations.fetch(slug)
    Enum.map(runtime.install, & &1.command)
  end

  describe "agents/0" do
    test "returns exactly six agents in the documented order" do
      keys = Enum.map(OnboardingPlugins.agents(), & &1.key)
      assert keys == ~w(claude_code copilot gemini codex opencode pi)
    end

    test "labels match the documented display order" do
      labels = Enum.map(OnboardingPlugins.agents(), & &1.label)
      assert labels == ["Claude Code", "Copilot", "Gemini", "Codex", "OpenCode", "Pi"]
    end

    test "every entry is an Agent struct with workflow steps and a URL" do
      for agent <- OnboardingPlugins.agents() do
        assert %Agent{} = agent
        assert agent.workflow_steps != [], agent.key

        for step <- agent.workflow_steps do
          assert step.title =~ ~r/\S/, agent.key
          assert step.command =~ ~r/\S/, agent.key
        end

        assert is_binary(agent.workflow_url) and agent.workflow_url != ""
      end
    end

    test "each agent's workflow install is the one its /integrations page gives" do
      for agent <- OnboardingPlugins.agents() do
        expected = Map.fetch!(@expected_commands, agent.key)
        commands = Enum.map(agent.workflow_steps, & &1.command)

        assert length(commands) == length(expected), agent.key

        for {command, start} <- Enum.zip(commands, expected) do
          assert String.starts_with?(command, start),
                 "#{agent.key}: #{inspect(command)} should start with #{inspect(start)}"
        end
      end
    end

    test "every workflow command is made only of install steps from KanbanWeb.Integrations" do
      for agent <- OnboardingPlugins.agents(), step <- agent.workflow_steps do
        integration = integration_commands(agent.integration)

        assert step.command in integration or
                 joined_steps?(step.command, integration),
               "#{agent.key}: #{inspect(step.command)} is not an install step on " <>
                 "/integrations/#{agent.integration}"
      end
    end

    test "every agent names an Integrations runtime and links to its listing or repository" do
      for agent <- OnboardingPlugins.agents() do
        assert {:ok, runtime} = Integrations.fetch(agent.integration), agent.key

        if agent.uses_marketplace do
          assert runtime.listing_kind == :marketplace, agent.key
          assert agent.workflow_url == runtime.listing_url, agent.key
        else
          assert String.starts_with?(runtime.docs_url, agent.workflow_url), agent.key
        end
      end
    end

    test "step titles come translated from KanbanWeb.Integrations in every locale" do
      for locale <- @locales do
        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          opencode = OnboardingPlugins.get("opencode")
          {:ok, runtime} = Integrations.fetch("opencode")

          assert Enum.map(opencode.workflow_steps, & &1.title) ==
                   Enum.map(runtime.install, & &1.title),
                 locale
        end)
      end
    end

    test "every workflow URL is a trusted https github link" do
      for agent <- OnboardingPlugins.agents() do
        assert String.starts_with?(agent.workflow_url, "https://github.com/cheezy/"),
               "#{agent.key} workflow_url is not a trusted github link: #{agent.workflow_url}"
      end
    end

    test "Claude Code, Copilot and Codex install through a marketplace; the others do not" do
      for agent <- OnboardingPlugins.agents() do
        expected = agent.key in ~w(claude_code copilot codex)

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

  # A block may join consecutive Integrations steps (Codex's marketplace add
  # and install) into one command to copy.
  defp joined_steps?(command, integration) do
    integration
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> command == a <> "\n" <> b end)
  end
end
