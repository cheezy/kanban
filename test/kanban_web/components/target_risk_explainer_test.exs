defmodule KanbanWeb.TargetRiskExplainerTest do
  @moduledoc """
  Unit tests for the `KanbanWeb.TargetRiskExplainer` function component. The
  explainer is fed hand-built rollup maps (the `:targets` shape returned by
  `Kanban.Targets.DeliveryRollup.build/2`, including the `:stalled_details`
  breakdown) so it exercises no database.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.TargetRiskExplainer

  defp render_explainer(targets) do
    assigns = %{targets: targets}

    rendered_to_string(~H"""
    <TargetRiskExplainer.target_risk_explainer targets={@targets} />
    """)
  end

  defp entry(status, target, details) do
    %{
      status: status,
      target: target,
      goals: [],
      agents: [],
      stalled_goals: [],
      stalled_agents: [],
      stalled_details: details
    }
  end

  defp target(id, name), do: %{id: id, name: name}
  defp goal(id, title), do: %{id: id, title: title}

  defp agent(name, opts) do
    %{
      name: name,
      stuck: Keyword.get(opts, :stuck, false),
      dormant: Keyword.get(opts, :dormant, false)
    }
  end

  describe "target_risk_explainer/1 with at-risk targets" do
    test "lists each at-risk target's stalled goals and the agents on them" do
      html =
        render_explainer([
          entry(:at_risk, target(1, "Launch"), [
            %{goal: goal(10, "Ship API"), agents: [agent("Ada", stuck: true)]}
          ])
        ])

      assert html =~ "data-target-risk-explainer"
      assert html =~ "Why targets are at risk"
      assert html =~ ~s(data-target-risk-card="1")
      assert html =~ "Launch"
      assert html =~ "At-risk"
      assert html =~ ~s(data-target-risk-goal="10")
      assert html =~ "Ship API"
      assert html =~ ~s(data-target-risk-agent="Ada")
      assert html =~ "Stuck"
    end

    test "pairs each stalled goal with only its own agents" do
      html =
        render_explainer([
          entry(:at_risk, target(1, "Launch"), [
            %{goal: goal(10, "Goal A"), agents: [agent("Ada", stuck: true)]},
            %{goal: goal(11, "Goal B"), agents: [agent("Zoe", dormant: true)]}
          ])
        ])

      # Ada appears in Goal A's block; Zoe in Goal B's — extract each block.
      block_a = between(html, ~s(data-target-risk-goal="10"), ~s(data-target-risk-goal="11"))
      assert block_a =~ "Ada"
      refute block_a =~ "Zoe"

      assert html =~ "Dormant"
    end

    test "uses dark-mode-safe tokens, not hardcoded colors" do
      html =
        render_explainer([
          entry(:at_risk, target(1, "Launch"), [
            %{goal: goal(10, "Ship API"), agents: [agent("Ada", stuck: true)]}
          ])
        ])

      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-blocked-soft)"
      refute html =~ "text-gray-"
      refute html =~ "bg-white"
      refute html =~ "#fff"
    end
  end

  describe "target_risk_explainer/1 with nothing at risk" do
    test "renders nothing when there are no targets" do
      refute render_explainer([]) =~ "data-target-risk-explainer"
    end

    test "renders nothing for an at-risk target that has no stalled work" do
      html = render_explainer([entry(:at_risk, target(1, "Launch"), [])])
      refute html =~ "data-target-risk-explainer"
    end

    test "ignores non-at-risk targets even when they carry stalled details" do
      html =
        render_explainer([
          entry(:on_track, target(1, "Launch"), [
            %{goal: goal(10, "Ship API"), agents: [agent("Ada", stuck: true)]}
          ])
        ])

      refute html =~ "data-target-risk-explainer"
    end
  end

  # The substring of `html` between the first occurrence of `from` and the
  # next occurrence of `to` (or end of string when `to` is absent).
  defp between(html, from, to) do
    [_, rest] = String.split(html, from, parts: 2)

    case String.split(rest, to, parts: 2) do
      [head, _] -> head
      [head] -> head
    end
  end
end
