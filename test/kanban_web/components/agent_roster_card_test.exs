defmodule KanbanWeb.AgentRosterCardTest do
  @moduledoc """
  Contract tests for `KanbanWeb.AgentRosterCard.card/1` — the left-roster
  presentational card on the Agents view.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Agents.Agent
  alias KanbanWeb.AgentRosterCard

  defp agent(overrides \\ %{}) do
    base = %Agent{
      name: "Claude",
      status: :idle,
      current_task: nil,
      capabilities: [],
      today: 0,
      last_7d: 0,
      success_rate: 0.0,
      claim_count: 0
    }

    struct(base, overrides)
  end

  describe "card/1 — markers and scope" do
    test "outermost element carries data-agent-roster-card and class stride-screen" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-roster-card"
      assert html =~ ~s(class="stride-screen")
    end

    test "renders the agent name" do
      assigns = %{agent: agent(%{name: "Codex"})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "Codex"
    end
  end

  describe "card/1 — owner line" do
    test "renders the owner name alongside the agent name when present" do
      assigns = %{
        agent: agent(%{name: "Claude", owner: %{id: 1, name: "Jeffrey", email: "j@x.io"}})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-owner"
      assert html =~ "Claude"
      assert html =~ "Jeffrey"
    end

    test "falls back to the owner email when the owner has no name" do
      assigns = %{agent: agent(%{owner: %{id: 1, name: nil, email: "owner@example.com"}})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-owner"
      assert html =~ "owner@example.com"
    end

    test "renders the agent name only when owner is nil (no broken layout)" do
      assigns = %{agent: agent(%{name: "Codex", owner: nil})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "Codex"
      refute html =~ "data-agent-owner"
    end

    test "owner line uses the muted ink token, not a hardcoded color" do
      assigns = %{agent: agent(%{owner: %{id: 1, name: "Jeffrey", email: "j@x.io"}})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "color: var(--ink-3)"
    end
  end

  describe "card/1 — status dot animation and token color" do
    test "renders the sp-pulse animation on the status dot" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-status-dot"
      assert html =~ "animation: sp-pulse 1.2s ease-in-out infinite"
    end

    test "renders var(--st-doing) for :working" do
      assigns = %{
        agent: agent(%{status: :working, current_task: %{identifier: "W1", title: "x"}})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "background: var(--st-doing)"
      assert html =~ ~s(data-agent-status="working")
    end

    test "renders var(--ink-3) for :waiting" do
      assigns = %{agent: agent(%{status: :waiting})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "background: var(--ink-3)"
      assert html =~ ~s(data-agent-status="waiting")
    end

    test "renders var(--ink-4) for :idle" do
      assigns = %{agent: agent(%{status: :idle})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "background: var(--ink-4)"
      assert html =~ ~s(data-agent-status="idle")
    end
  end

  describe "card/1 — current-task pill" do
    test "renders the pill only when status is :working with a task" do
      assigns = %{
        agent: agent(%{status: :working, current_task: %{identifier: "W42", title: "Wire up x"}})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-current-task"
      assert html =~ "W42"
      assert html =~ "Wire up x"
    end

    test "hides the pill when status is :idle even if current_task is present" do
      assigns = %{
        agent: agent(%{status: :idle, current_task: %{identifier: "W42", title: "Stale"}})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      refute html =~ "data-agent-current-task"
    end

    test "hides the pill when current_task is nil" do
      assigns = %{agent: agent(%{status: :working, current_task: nil})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      refute html =~ "data-agent-current-task"
    end
  end

  describe "card/1 — capability pills" do
    test "hides the capabilities section when the list is empty" do
      assigns = %{agent: agent(%{capabilities: []})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      refute html =~ "data-agent-capabilities"
    end

    test "renders each capability with the violet token palette" do
      assigns = %{agent: agent(%{capabilities: ["elixir", "phoenix"]})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-capabilities"
      assert html =~ "elixir"
      assert html =~ "phoenix"
      assert html =~ "var(--stride-violet)"
    end
  end

  describe "card/1 — selection and interactivity" do
    test "wires phx-click to on_select and phx-value-agent to the agent name" do
      assigns = %{agent: agent(%{name: "Codex"})}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} on_select="select_agent" />
        """)

      assert html =~ ~s(phx-click="select_agent")
      assert html =~ ~s(phx-value-agent="Codex")
    end

    test "is a keyboard-operable button when on_select is set" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} on_select="select_agent" />
        """)

      assert html =~ ~s(role="button")
      assert html =~ ~s(tabindex="0")
      assert html =~ "focus-visible:outline"
    end

    test "renders aria-pressed=\"true\" and the violet highlight when selected?" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} on_select="select_agent" selected?={true} />
        """)

      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~s(data-agent-selected="true")
      assert html =~ "border: 1px solid var(--stride-violet)"
      assert html =~ "background: var(--stride-violet-soft)"
    end

    test "renders aria-pressed=\"false\" and no highlight when not selected" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} on_select="select_agent" />
        """)

      assert html =~ ~s(aria-pressed="false")
      assert html =~ ~s(data-agent-selected="false")
      assert html =~ "border: 1px solid var(--line)"
      assert html =~ "background: var(--surface)"
    end

    test "omits button semantics when on_select is nil (presentational default)" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      refute html =~ ~s(role="button")
      refute html =~ "aria-pressed"
      refute html =~ "tabindex"
      refute html =~ "phx-click"
    end
  end

  describe "card/1 — stats grid" do
    test "renders the four-cell grid with tabular-nums" do
      assigns = %{
        agent: agent(%{today: 5, last_7d: 21, success_rate: 0.875, claim_count: 30})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ "data-agent-stats-grid"
      assert html =~ "font-variant-numeric: tabular-nums"

      assert html =~ ~r{<dd[^>]*>\s*5\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*21\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*88%\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*30\s*</dd>}
    end

    test "labels each of the four stats in its own cell" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ ~r{<dt[^>]*>\s*Today\s*</dt>}
      assert html =~ ~r{<dt[^>]*>\s*7d\s*</dt>}
      assert html =~ ~r{<dt[^>]*>\s*Success\s*</dt>}
      assert html =~ ~r{<dt[^>]*>\s*Claims\s*</dt>}
    end

    test "uses a stable two-column layout that does not collapse to four columns" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      # A 2x2 grid keeps each stat in a wide cell at the fixed roster width so
      # Success and Claims never overlap. The old narrow four-up layout
      # (sm:grid-cols-4) is what caused the overlap and must not return.
      assert html =~ "grid-cols-2"
      refute html =~ "sm:grid-cols-4"
    end

    test "keeps wide values readable without overlap" do
      assigns = %{
        agent: agent(%{today: 644, last_7d: 644, success_rate: 1.0, claim_count: 644})
      }

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      # A three-digit claim count and a 100% success rate must each render in
      # their own cell rather than spilling over a neighbour.
      assert html =~ ~r{<dd[^>]*>\s*100%\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*644\s*</dd>}
    end

    test "renders zeros for an idle agent with no activity" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      assert html =~ ~r{<dd[^>]*>\s*0\s*</dd>}
      assert html =~ ~r{<dd[^>]*>\s*0%\s*</dd>}
    end
  end

  describe "card/1 — target annotation" do
    defp annotation(status) do
      %{target: %{name: "Launch"}, goal: %{title: "Ship the API"}, status: status}
    end

    test "renders the target and goal when an annotation is given" do
      assigns = %{agent: agent(), annotation: annotation(:at_risk)}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} annotation={@annotation} />
        """)

      assert html =~ "data-agent-target-annotation"
      assert html =~ ~s(data-agent-target-status="at_risk")
      assert html =~ "Launch"
      assert html =~ "Ship the API"
      # At-risk targets accent the annotation amber.
      assert html =~ "var(--st-doing)"
    end

    test "renders no annotation when none is given (default nil)" do
      assigns = %{agent: agent()}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} />
        """)

      refute html =~ "data-agent-target-annotation"
    end

    test "uses a neutral accent for an on-track target" do
      assigns = %{agent: agent(), annotation: annotation(:on_track)}

      html =
        rendered_to_string(~H"""
        <AgentRosterCard.card agent={@agent} annotation={@annotation} />
        """)

      assert html =~ ~s(data-agent-target-status="on_track")
      assert html =~ "var(--line)"
    end
  end
end
