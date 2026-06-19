defmodule KanbanWeb.AgentDetailPanelTest do
  @moduledoc """
  Unit tests for the view-only `KanbanWeb.AgentDetailPanel` component, which
  renders the `Kanban.Agents.agent_detail/2` data shape.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Agents.Event
  alias KanbanWeb.AgentDetailPanel

  defp detail(overrides \\ %{}) do
    base = %{
      name: "Claude",
      current_task: %{identifier: "W42", title: "Do the thing"},
      claims: [%{identifier: "W42", title: "Do the thing", at: ~U[2026-06-19 14:30:00Z]}],
      failures: [%{identifier: "W7", title: "Broke it", at: ~U[2026-06-18 09:00:00Z]}],
      recent_activity: [
        %Event{
          kind: :complete,
          actor: "Claude",
          identifier: "W42",
          title: "Do the thing",
          at: ~U[2026-06-19 14:30:00Z]
        }
      ]
    }

    Map.merge(base, overrides)
  end

  defp render_panel(detail) do
    assigns = %{detail: detail}

    rendered_to_string(~H"""
    <AgentDetailPanel.panel detail={@detail} />
    """)
  end

  test "renders all detail sections for a populated agent" do
    html = render_panel(detail())

    assert html =~ "data-agent-detail-panel"
    assert html =~ "Claude"
    assert html =~ "Current work"
    assert html =~ "W42"
    assert html =~ "Do the thing"
    assert html =~ ~s(data-agent-detail-section="claims")
    assert html =~ ~s(data-agent-detail-section="failures")
    assert html =~ "W7"
    assert html =~ "Recent activity"
    assert html =~ ~s(data-agent-detail-event="complete")
    # View-only: no control buttons in the panel.
    refute html =~ "<button"
  end

  test "handles a missing current task" do
    html = render_panel(detail(%{current_task: nil}))

    assert html =~ "data-agent-detail-no-current"
    assert html =~ "No active task"
  end

  test "shows the empty caption when there are no failures" do
    html = render_panel(detail(%{failures: []}))

    assert html =~ ~s(data-agent-detail-section="failures")
    assert html =~ "None"
  end

  test "shows the empty caption when there is no recent activity" do
    html = render_panel(detail(%{recent_activity: []}))

    assert html =~ "No recent activity."
    refute html =~ "data-agent-detail-event="
  end
end
