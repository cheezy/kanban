defmodule KanbanWeb.MetricsAgentLeaderboardTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsAgentLeaderboard.leaderboard/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsAgentLeaderboard

  defp render_board(rows) do
    assigns = %{rows: rows}

    rendered_to_string(~H"""
    <MetricsAgentLeaderboard.leaderboard rows={@rows} />
    """)
  end

  defp agent_row(overrides \\ %{}) do
    Map.merge(
      %{name: "Claude", kind: :agent, completed: 28, success_pct: 96.0},
      overrides
    )
  end

  defp human_row(overrides \\ %{}) do
    Map.merge(
      %{name: "Jamie K", kind: :human, completed: 7, success_pct: 100.0, user_id: 42},
      overrides
    )
  end

  describe "leaderboard/1 — markers and structure" do
    test "renders the root marker and the title" do
      html = render_board([agent_row()])
      assert html =~ "data-metrics-agent-leaderboard"
      assert html =~ "Agents · last 14 days"
      assert html =~ "by completed"
    end

    test "renders one row per entry with kind data attribute" do
      html = render_board([agent_row(), human_row()])

      rows = Regex.scan(~r/data-metrics-agent-leaderboard-row/, html)
      assert length(rows) == 2

      assert html =~ ~s(data-metrics-agent-leaderboard-kind="agent")
      assert html =~ ~s(data-metrics-agent-leaderboard-kind="human")
    end

    test "renders the per-row name, completed count, and success pct cells" do
      html = render_board([agent_row(%{name: "Claude", completed: 28, success_pct: 96.0})])
      assert html =~ "Claude"
      assert html =~ ~s(data-metrics-agent-leaderboard-completed)
      assert html =~ ~s(data-metrics-agent-leaderboard-success)
      assert html =~ "28"
      assert html =~ "96%"
    end
  end

  describe "leaderboard/1 — bar scaling" do
    test "the largest completion fills the bar at 100%" do
      html =
        render_board([
          agent_row(%{name: "Top", completed: 30}),
          agent_row(%{name: "Mid", completed: 15}),
          agent_row(%{name: "Low", completed: 5})
        ])

      top_row =
        Regex.run(
          ~r/<div[^>]*data-metrics-agent-leaderboard-row[\s\S]*?Top[\s\S]*?<\/div>\s*<\/div>/,
          html
        )
        |> List.first()

      assert top_row =~ "width: 100%"
    end

    test "smaller completions scale proportionally" do
      html =
        render_board([
          agent_row(%{name: "Top", completed: 20}),
          agent_row(%{name: "Half", completed: 10})
        ])

      half_row =
        Regex.run(
          ~r/<div[^>]*data-metrics-agent-leaderboard-row[\s\S]*?Half[\s\S]*?<\/div>\s*<\/div>/,
          html
        )
        |> List.first()

      assert half_row =~ "width: 50%"
    end

    test "agent rows use stride-orange bar, human rows use stride-violet" do
      html = render_board([agent_row(), human_row()])

      agent =
        Regex.run(
          ~r/data-metrics-agent-leaderboard-kind="agent"[\s\S]*?data-metrics-agent-leaderboard-bar[^>]*>/,
          html
        )
        |> List.first()

      human =
        Regex.run(
          ~r/data-metrics-agent-leaderboard-kind="human"[\s\S]*?data-metrics-agent-leaderboard-bar[^>]*>/,
          html
        )
        |> List.first()

      assert agent =~ "var(--stride-orange)"
      assert human =~ "var(--stride-violet)"
    end
  end

  describe "leaderboard/1 — empty state" do
    test "renders the localized empty-state copy when rows is empty" do
      html = render_board([])
      assert html =~ "data-metrics-agent-leaderboard-empty"
      assert html =~ "No completions in the last 14 days."
    end

    test "does not render any row markers in the empty state" do
      html = render_board([])
      refute html =~ "data-metrics-agent-leaderboard-row"
    end
  end

  describe "leaderboard/1 — accessibility and tokens" do
    test "no hardcoded Tailwind greys or daisyUI base colors" do
      html = render_board([agent_row(), human_row()])
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
    end

    test "rounds float success_pct to the nearest integer percent" do
      html = render_board([agent_row(%{success_pct: 83.4})])
      assert html =~ "83%"
    end
  end

  describe "leaderboard/1 — avatar selection" do
    test "agent rows render the agent-* palette via KanbanWeb.Avatar" do
      html = render_board([agent_row(%{name: "Claude"})])
      # Avatar.avatar renders the first letter of the name.
      assert html =~ ">\n  C\n<"
    end

    test "human rows render the human-* palette" do
      html = render_board([human_row(%{name: "Jamie K"})])
      # Avatar renders the first letter of each of the first two words.
      assert html =~ ">\n  JK\n<"
    end
  end
end
