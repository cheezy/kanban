defmodule KanbanWeb.AgentActivityFeedTest do
  @moduledoc """
  Contract tests for `KanbanWeb.AgentActivityFeed.feed/1` — the right-rail
  filter-tab row plus scrolling activity list on the Agents view.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Agents.Event
  alias KanbanWeb.AgentActivityFeed

  defp event(overrides \\ %{}) do
    base = %Event{
      kind: :claim,
      actor: "Claude",
      identifier: "W42",
      title: "Wire up x",
      at: ~U[2026-05-15 14:32:00Z],
      move_to: nil,
      flag: nil,
      cycle_time_minutes: nil
    }

    struct(base, overrides)
  end

  defp render(events, filter, on_filter_change \\ "filter", timezone \\ "Etc/UTC") do
    assigns = %{
      events: events,
      filter: filter,
      on_filter_change: on_filter_change,
      timezone: timezone
    }

    rendered_to_string(~H"""
    <AgentActivityFeed.feed
      events={@events}
      filter={@filter}
      on_filter_change={@on_filter_change}
      timezone={@timezone}
    />
    """)
  end

  describe "feed/1 — markers and empty state" do
    test "outermost element carries data-agent-feed and class stride-screen" do
      html = render([], :all)

      assert html =~ "data-agent-feed"
      assert html =~ ~s(class="stride-screen")
    end

    test "renders the gettext empty-state copy when events list is empty" do
      html = render([], :all)

      assert html =~ "data-agent-feed-empty"
      assert html =~ "No recent activity."
    end

    test "renders one row per event with the data-agent-feed-row marker" do
      events = [event(), event(%{identifier: "W43"}), event(%{identifier: "W44"})]

      html = render(events, :all)

      rows = Regex.scan(~r/data-agent-feed-row/, html)
      assert length(rows) == 3
    end
  end

  describe "feed/1 — owner alongside actor" do
    test "renders the owner alongside the actor agent name when present" do
      events = [event(%{actor: "Claude", owner: %{id: 1, name: "Jeffrey", email: "j@x.io"}})]

      html = render(events, :all)

      assert html =~ "data-agent-feed-owner"
      assert html =~ "Claude"
      assert html =~ "Jeffrey"
    end

    test "falls back to the owner email when the owner has no name" do
      events = [event(%{owner: %{id: 1, name: nil, email: "owner@example.com"}})]

      html = render(events, :all)

      assert html =~ "data-agent-feed-owner"
      assert html =~ "owner@example.com"
    end

    test "degrades gracefully to actor-only when owner is nil" do
      events = [event(%{actor: "Claude", owner: nil})]

      html = render(events, :all)

      assert html =~ "Claude"
      refute html =~ "data-agent-feed-owner"
    end

    test "owner uses the muted ink token, not a hardcoded color" do
      events = [event(%{owner: %{id: 1, name: "Jeffrey", email: "j@x.io"}})]

      html = render(events, :all)

      assert html =~ "color: var(--ink-3)"
    end
  end

  describe "feed/1 — filter tabs" do
    test "renders all four filter tabs" do
      html = render([], :all)

      assert html =~ ~s(data-agent-feed-tab="all")
      assert html =~ ~s(data-agent-feed-tab="claims")
      assert html =~ ~s(data-agent-feed-tab="reviewed")
      assert html =~ ~s(data-agent-feed-tab="completions")

      # The renamed tab surfaces the translated "Reviewed" label.
      assert html =~ "Reviewed"
      refute html =~ "Hooks"
    end

    test "highlights the active filter tab via aria-selected" do
      html = render([], :claims)

      assert html =~ ~r/data-agent-feed-tab="claims"[^>]*aria-selected="true"/
      assert html =~ ~r/data-agent-feed-tab="all"[^>]*aria-selected="false"/
    end

    test "the active tab uses the ink background palette" do
      html = render([], :reviewed)

      assert html =~
               ~r/data-agent-feed-tab="reviewed"[^>]*style="[^"]*background: var\(--ink\)/
    end

    test "tab clicks emit the configured phx-click event with phx-value-filter" do
      html = render([], :all, "select-filter")

      assert html =~ ~s(phx-click="select-filter")
      assert html =~ ~s(phx-value-filter="claims")
      assert html =~ ~s(phx-value-filter="all")
    end
  end

  describe "feed/1 — kind icon and tone per event kind" do
    test "claim event renders hero-arrow-right with the doing tone" do
      html = render([event(%{kind: :claim})], :all)

      assert html =~ "hero-arrow-right"
      assert html =~ ~s(data-agent-feed-kind="claim")
      assert html =~ "var(--st-doing)"
    end

    test "complete event renders hero-check with the review tone" do
      html = render([event(%{kind: :complete})], :all)

      assert html =~ "hero-check"
      assert html =~ ~s(data-agent-feed-kind="complete")
      assert html =~ "var(--st-review)"
    end

    test "review event renders hero-check with the done tone" do
      html = render([event(%{kind: :review})], :all)

      assert html =~ "hero-check"
      assert html =~ ~s(data-agent-feed-kind="review")
      assert html =~ "var(--st-done)"
    end

    test "create event renders hero-plus" do
      html = render([event(%{kind: :create})], :all)

      assert html =~ "hero-plus"
      assert html =~ ~s(data-agent-feed-kind="create")
    end

    test "unclaim event renders hero-arrow-uturn-left" do
      html = render([event(%{kind: :unclaim})], :all)

      assert html =~ "hero-arrow-uturn-left"
      assert html =~ ~s(data-agent-feed-kind="unclaim")
    end

    test "each row carries a kind-colored left accent via the shared kind tone" do
      for {kind, tone} <- [
            {:claim, "var(--st-doing)"},
            {:complete, "var(--st-review)"},
            {:review, "var(--st-done)"},
            {:create, "var(--ink-3)"}
          ] do
        html = render([event(%{kind: kind})], :all)

        assert html =~ "border-left: 3px solid #{tone}"
      end
    end

    test "active kinds carry a soft kind-tinted row background via kind_soft" do
      for {kind, soft} <- [
            {:claim, "var(--st-doing-soft)"},
            {:complete, "var(--st-review-soft)"},
            {:review, "var(--st-done-soft)"}
          ] do
        html = render([event(%{kind: kind})], :all)

        assert html =~ "background: #{soft}"
      end
    end

    test "baseline kinds (create/unclaim) stay transparent to keep the feed restrained" do
      for kind <- [:create, :unclaim] do
        html = render([event(%{kind: kind})], :all)

        assert html =~ "background: transparent"
      end
    end
  end

  describe "feed/1 — optional trailing chips" do
    test "renders the move-to chip when event.move_to is present" do
      html = render([event(%{move_to: :review})], :all)

      assert html =~ "data-agent-feed-move-chip"
      assert html =~ "Review"
    end

    test "renders the cycle-time chip when cycle_time_minutes is present" do
      html = render([event(%{kind: :complete, cycle_time_minutes: 90})], :all)

      assert html =~ "data-agent-feed-cycle-chip"
      assert html =~ "1h 30m"
    end

    test "renders the cycle-time chip in minutes for sub-hour durations" do
      html = render([event(%{kind: :complete, cycle_time_minutes: 42})], :all)

      assert html =~ "data-agent-feed-cycle-chip"
      assert html =~ "42m"
    end

    test "renders no trailing chips when neither move_to nor cycle_time_minutes is set" do
      html = render([event()], :all)

      refute html =~ "data-agent-feed-move-chip"
      refute html =~ "data-agent-feed-cycle-chip"
    end
  end

  describe "feed/1 — actor avatar edge cases" do
    test "renders a consistent fallback avatar (not an empty box) when event.actor is nil" do
      html = render([event(%{actor: nil})], :all)

      # The fallback is now a labeled neutral avatar, not an empty placeholder box,
      # so claim/create rows line up with completion rows (D82).
      assert html =~ "data-agent-feed-avatar-fallback"
      assert html =~ "Unknown agent"
      # Still an agent-shaped square (4px radius), matching real avatars.
      assert html =~ "border-radius: 4px"
    end

    test "renders an Avatar for an unknown actor name (fallback palette)" do
      html = render([event(%{actor: "Unknown Agent"})], :all)

      assert html =~ "Unknown Agent"
    end
  end

  describe "feed/1 — time formatting" do
    test "renders a tabular-nums HH:MM time column with datetime attribute" do
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all)

      assert html =~ ~s(datetime="2026-05-15T14:32:00Z")
      assert html =~ "14:32"
      assert html =~ "tabular-nums"
    end

    test "converts a UTC event time to the given IANA zone for display" do
      # 14:32 UTC is 10:32 in America/New_York (EDT, UTC-4) on this date.
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all, "filter", "America/New_York")

      assert html =~ "10:32"
      refute html =~ ">14:32<"
      # The machine-readable datetime attribute stays the canonical UTC ISO8601.
      assert html =~ ~s(datetime="2026-05-15T14:32:00Z")
    end

    test "falls back to UTC display when the timezone is unknown" do
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all, "filter", "Not/AZone")

      assert html =~ "14:32"
    end
  end

  describe "feed/1 — date grouping" do
    test "renders a date-header row before the group" do
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all)

      assert html =~ "data-agent-feed-date-header"
    end

    test "events spanning two local dates produce two date-group headers" do
      events = [
        event(%{at: ~U[2026-05-15 14:32:00Z]}),
        event(%{identifier: "W43", at: ~U[2026-05-14 09:00:00Z]})
      ]

      html = render(events, :all)

      headers = Regex.scan(~r/data-agent-feed-date-header/, html)
      assert length(headers) == 2
      # Both rows still render — grouping wraps rows, it does not drop them.
      assert length(Regex.scan(~r/data-agent-feed-row/, html)) == 2
    end

    test "groups an event near midnight under its local date, not its UTC date" do
      # 02:00 UTC on May 15 is 22:00 on May 14 in America/New_York — the row
      # must land under the May 14 header, not May 15.
      html = render([event(%{at: ~U[2026-05-15 02:00:00Z]})], :all, "filter", "America/New_York")

      assert html =~ "May 14"
      refute html =~ "May 15"
    end

    test "labels the most recent group Today in the viewer's zone" do
      html = render([event(%{at: DateTime.utc_now()})], :all, "filter", "Etc/UTC")

      assert html =~ "Today"
    end

    test "labels the prior day's group Yesterday" do
      yesterday = DateTime.add(DateTime.utc_now(), -1, :day)
      html = render([event(%{at: yesterday})], :all, "filter", "Etc/UTC")

      assert html =~ "Yesterday"
    end
  end
end
