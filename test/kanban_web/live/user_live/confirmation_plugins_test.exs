defmodule KanbanWeb.UserLive.ConfirmationPluginsTest do
  @moduledoc """
  Drift guard: proves the `KanbanWeb.OnboardingPlugins` registry and the plugin
  picker rendered on the confirmed onboarding page stay in agreement.

  The test is data-driven — it iterates every entry the registry returns rather
  than hardcoding the agent list, so adding a seventh agent (or changing a
  command/URL) is automatically checked against what the page actually renders.
  Only the selected agent's panel is in the DOM at a time, so each agent's tab is
  clicked before asserting that agent's commands/links.
  """

  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias KanbanWeb.OnboardingPlugins

  # Escape a value the same way HEEx does when interpolating it into markup, so a
  # command containing quotes (e.g. OpenCode's opencode.json snippet) still matches
  # what is actually rendered.
  defp rendered(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  setup %{conn: conn} do
    user = unconfirmed_user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, url)
      end)

    {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
    %{lv: lv}
  end

  describe "registry ↔ onboarding picker consistency" do
    test "every registry agent renders a tab on the confirmed page", %{lv: lv} do
      for agent <- OnboardingPlugins.agents() do
        assert has_element?(
                 lv,
                 ~s{button[role="tab"][phx-value-agent="#{agent.key}"]},
                 agent.label
               ),
               "#{agent.key}: no tab rendered for this registry agent"
      end
    end

    test "selecting each agent surfaces its workflow command + link and ideation reference", %{
      lv: lv
    } do
      for agent <- OnboardingPlugins.agents() do
        html = lv |> element(~s{button[phx-value-agent="#{agent.key}"]}) |> render_click()

        for {step, index} <- Enum.with_index(agent.workflow_steps) do
          assert html =~ rendered(step.command),
                 "#{agent.key}: workflow command #{index} is missing from the rendered panel"

          assert has_element?(lv, "#workflow-copy-#{agent.key}-#{index}"),
                 "#{agent.key}: workflow command #{index} has no copy button"
        end

        # A title shows only when the install takes more than one block.
        for step <- agent.workflow_steps, length(agent.workflow_steps) > 1 do
          assert html =~ rendered(step.title), "#{agent.key}: step title missing"
        end

        assert html =~ rendered(agent.workflow_url),
               "#{agent.key}: workflow URL is missing from the rendered panel"

        if agent.ideation_command do
          assert html =~ rendered(agent.ideation_command),
                 "#{agent.key}: ideation command is missing from the rendered panel"

          assert html =~ rendered(agent.ideation_url),
                 "#{agent.key}: ideation URL is missing from the rendered panel"
        else
          assert html =~ "No separate ideation plugin yet.",
                 "#{agent.key}: expected the no-ideation helper for an agent with no ideation port"
        end
      end
    end
  end
end
