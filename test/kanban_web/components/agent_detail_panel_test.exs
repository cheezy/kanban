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

  # Renders the panel. With no `:expanded_sections` opt every section defaults
  # to expanded (nil set); pass a MapSet to collapse the sections it omits.
  defp render_panel(detail, opts \\ []) do
    assigns = %{detail: detail, expanded: Keyword.get(opts, :expanded_sections)}

    rendered_to_string(~H"""
    <AgentDetailPanel.panel
      detail={@detail}
      expanded_sections={@expanded}
      on_toggle="toggle_detail_section"
    />
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
  end

  test "each section title row is a collapse toggle reflecting expanded state" do
    html = render_panel(detail())

    # Every category exposes a stable toggle marker, wired to the LiveView event.
    for section <- ~w(current claims failures activity) do
      assert html =~ ~s(data-agent-detail-section-toggle="#{section}")
    end

    assert html =~ ~s(phx-click="toggle_detail_section")
    assert html =~ ~s(phx-value-section="claims")
    # Expanded by default: aria-expanded true and the down chevron.
    assert html =~ ~s(aria-expanded="true")
    assert html =~ "hero-chevron-down"
  end

  test "a collapsed section hides its body and flips the chevron, others stay open" do
    # Everything expanded except failures.
    html = render_panel(detail(), expanded_sections: MapSet.new(~w(current claims activity)))

    # Failures body is hidden, but its toggle row (and count) remain visible.
    refute html =~ "W7"
    refute html =~ "Broke it"
    assert html =~ ~s(data-agent-detail-section-toggle="failures")
    assert html =~ ~s(aria-expanded="false")
    assert html =~ "hero-chevron-right"

    # A still-expanded section keeps rendering its body.
    assert html =~ "W42"
    assert html =~ "hero-chevron-down"
  end

  test "title rows carry the activity-list highlight tokens, not invented colors" do
    html = render_panel(detail())

    # Claims + Current work use the claim/doing soft tint; failures the blocked
    # soft tint; recent activity the neutral sunken surface. All theme-aware
    # tokens reused from TaskTokens / the status palette.
    assert html =~ "var(--st-doing-soft)"
    assert html =~ "var(--st-blocked-soft)"
    assert html =~ "var(--surface-sunken)"
    # Left-accent tones mirror the activity feed rows.
    assert html =~ "var(--st-doing)"
    assert html =~ "var(--st-blocked)"
  end

  test "count badges and labels stay on the title rows, even when collapsed" do
    # Collapse claims and activity; their labels + count badges must still show.
    html = render_panel(detail(), expanded_sections: MapSet.new(~w(current failures)))

    assert html =~ ~s(data-agent-detail-section-toggle="claims")
    assert html =~ "Claims"
    assert html =~ ~s(data-agent-detail-section-toggle="activity")
    assert html =~ "Recent activity"
    # The count badge markup (tabular-nums span) is still emitted on the row.
    assert html =~ "font-variant-numeric: tabular-nums"
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

  test "a collapsed section omits its empty-state caption too" do
    html =
      render_panel(detail(%{failures: []}),
        expanded_sections: MapSet.new(~w(current claims activity))
      )

    # The failures section is collapsed, so even its "None" caption is hidden.
    assert html =~ ~s(data-agent-detail-section-toggle="failures")
    refute html =~ "None"
  end
end
