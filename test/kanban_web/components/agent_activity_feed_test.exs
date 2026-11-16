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
    test "renders a tabular-nums local time column with datetime attribute" do
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all)

      assert html =~ ~s(datetime="2026-05-15T14:32:00Z")
      assert html =~ ">2:32 PM</time>"
      assert html =~ "tabular-nums"
    end

    test "converts a UTC event time to the given IANA zone for display" do
      # 14:32 UTC is 10:32 AM in America/New_York (EDT, UTC-4) on this date.
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all, "filter", "America/New_York")

      assert html =~ ">10:32 AM</time>"
      refute html =~ ">2:32 PM</time>"
      # The machine-readable datetime attribute stays the canonical UTC ISO8601.
      assert html =~ ~s(datetime="2026-05-15T14:32:00Z")
    end

    test "renders timestamps in the viewer's timezone" do
      at = ~U[2026-11-11 04:56:00Z]

      en = render([event(%{at: at})], :all, "filter", "America/Toronto")
      assert en =~ ">11:56 PM</time>"
      assert en =~ ~s(title="November 10, 2026 at 11:56 PM EST")
      refute en =~ "UTC"

      de =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          render([event(%{at: at})], :all, "filter", "America/Toronto")
        end)

      assert de =~ ">23:56</time>"
      assert de =~ ~s(title="10. November 2026, 23:56 EST")

      ja =
        Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
          render([event(%{at: at})], :all, "filter", "America/Toronto")
        end)

      assert ja =~ ">23:56</time>"
      assert ja =~ "11月10日 (火)"
    end

    test "follows a DST transition in the viewer's zone" do
      # Toronto springs forward at 2 AM local on 2026-03-08 (07:00 UTC).
      events = [
        event(%{identifier: "W1", at: ~U[2026-03-08 06:30:00Z]}),
        event(%{identifier: "W2", at: ~U[2026-03-08 07:30:00Z]})
      ]

      html = render(events, :all, "filter", "America/Toronto")

      assert html =~ ">1:30 AM</time>"
      assert html =~ ~s(title="March 8, 2026 at 1:30 AM EST")
      assert html =~ ">3:30 AM</time>"
      assert html =~ ~s(title="March 8, 2026 at 3:30 AM EDT")
    end

    test "falls back to UTC for an unknown zone" do
      html = render([event(%{at: ~U[2026-05-15 14:32:00Z]})], :all, "filter", "Not/AZone")

      assert html =~ ">2:32 PM</time>"
      assert html =~ ~s(title="May 15, 2026 at 2:32 PM UTC")
    end

    test "uses the process zone when no timezone attr is given" do
      KanbanWeb.LocalTime.put_timezone("America/Toronto")
      assigns = %{events: [event(%{at: ~U[2026-11-11 04:56:00Z]})]}

      html =
        rendered_to_string(~H"""
        <AgentActivityFeed.feed events={@events} filter={:all} on_filter_change="filter" />
        """)

      assert html =~ ">11:56 PM</time>"

      KanbanWeb.LocalTime.put_timezone("Not/AZone")

      html =
        rendered_to_string(~H"""
        <AgentActivityFeed.feed events={@events} filter={:all} on_filter_change="filter" />
        """)

      assert html =~ ">4:56 AM</time>"
    end

    test "renders nothing for a nil timestamp" do
      html = render([event(%{at: nil})], :all)

      refute html =~ "<time"
      refute html =~ "data-agent-feed-row"
      assert html =~ "No recent activity."

      mixed = render([event(%{identifier: "W1", at: nil}), event(%{identifier: "W2"})], :all)

      assert length(Regex.scan(~r/data-agent-feed-row/, mixed)) == 1
      assert mixed =~ "W2"
      refute mixed =~ "W1"
    end

    test "keeps an ISO 8601 UTC datetime attribute" do
      at = ~U[2026-11-11 04:56:00Z]

      for zone <- ["America/Toronto", "Pacific/Kiritimati", "Etc/UTC"],
          locale <- ["en", "de", "zh"] do
        html =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            render([event(%{at: at})], :all, "filter", zone)
          end)

        assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
      end
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

    test "rolls a late-evening timestamp back to the local day" do
      # 02:00 UTC on Friday May 15 is 10 PM on Thursday May 14 in New York.
      events = [event(%{at: ~U[2026-05-15 02:00:00Z]})]
      html = render(events, :all, "filter", "America/New_York")

      assert html =~ "Thu, May 14"
      assert html =~ ">10:00 PM</time>"
      refute html =~ "May 15"

      de =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          render(events, :all, "filter", "America/New_York")
        end)

      assert de =~ "Do., 14. Mai"
      assert de =~ ">22:00</time>"
    end

    test "localises the weekday-date header in the current language" do
      events = [event(%{at: ~U[2026-05-15 14:32:00Z]})]

      for {locale, header} <- [{"en", "Fri, May 15"}, {"fr", "ven. 15 mai"}, {"zh", "5月15日 (周五)"}] do
        html = Gettext.with_locale(KanbanWeb.Gettext, locale, fn -> render(events, :all) end)
        assert html =~ header
      end
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

  describe "feed/1 — delivery tether" do
    defp render_tethered(events, tethers) do
      assigns = %{events: events, tethers: tethers}

      rendered_to_string(~H"""
      <AgentActivityFeed.feed
        events={@events}
        filter={:all}
        on_filter_change="filter"
        timezone="Etc/UTC"
        tethers={@tethers}
      />
      """)
    end

    test "renders the target and goal the event's own task belongs to" do
      # A no-owner actor keys as {name, "none"}, matching the feed's identity
      # rule; the inner map is keyed by goal id, matched by the event's parent_id.
      tethers = %{
        {"Claude", "none"} => %{
          7 => %{
            target: %{name: "Launch"},
            goal: %{id: 7, title: "Ship the API"},
            status: :at_risk
          }
        }
      }

      html = render_tethered([event(%{parent_id: 7})], tethers)

      assert html =~ "data-agent-feed-tether"
      assert html =~ ~s(data-agent-feed-tether-status="at_risk")
      assert html =~ "Launch"
      assert html =~ "Ship the API"
      # At-risk tethers accent the target name amber.
      assert html =~ "var(--st-doing)"
    end

    test "resolves each row's tether from its own parent goal, not a sibling goal (D121)" do
      # One actor advancing two goals: each row must tether to the goal ITS task
      # belongs to (matched by parent_id), never a single collapsed goal.
      tethers = %{
        {"Claude", "none"} => %{
          7 => %{
            target: %{name: "Launch"},
            goal: %{id: 7, title: "Ship the API"},
            status: :at_risk
          },
          9 => %{
            target: %{name: "Polish"},
            goal: %{id: 9, title: "Refine the UI"},
            status: :on_track
          }
        }
      }

      events = [
        event(%{identifier: "W42", parent_id: 7}),
        event(%{identifier: "W43", parent_id: 9})
      ]

      html = render_tethered(events, tethers)

      tether_texts =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-agent-feed-tether]")
        |> Enum.map(&LazyHTML.text/1)

      assert Enum.any?(tether_texts, &(&1 =~ "Launch" and &1 =~ "Ship the API"))
      assert Enum.any?(tether_texts, &(&1 =~ "Polish" and &1 =~ "Refine the UI"))
    end

    test "renders no tether when the event's parent goal is not in the actor's set" do
      # The actor advances goal 7, but this event's task belongs to goal 99 —
      # show no goal rather than borrowing the actor's other goal label.
      tethers = %{
        {"Claude", "none"} => %{
          7 => %{
            target: %{name: "Launch"},
            goal: %{id: 7, title: "Ship the API"},
            status: :on_track
          }
        }
      }

      html = render_tethered([event(%{parent_id: 99})], tethers)

      refute html =~ "data-agent-feed-tether"
    end

    test "renders no tether when the actor has none" do
      html = render_tethered([event(%{actor: "Nomad", parent_id: 7})], %{})

      refute html =~ "data-agent-feed-tether"
    end

    test "renders no tether for an actorless event" do
      tethers = %{
        {"Claude", "none"} => %{
          7 => %{target: %{name: "Launch"}, goal: %{id: 7, title: "G"}, status: :on_track}
        }
      }

      html = render_tethered([event(%{actor: nil, parent_id: 7})], tethers)

      refute html =~ "data-agent-feed-tether"
    end
  end

  describe "feed/1 on the Agents page" do
    setup [:register_and_log_in_user]

    defp seed_claim_at(user, at) do
      column =
        user |> Kanban.BoardsFixtures.board_fixture() |> Kanban.ColumnsFixtures.column_fixture()

      {:ok, _} =
        column
        |> Kanban.TasksFixtures.task_fixture()
        |> Kanban.Tasks.update_task(%{
          created_by_agent: "Claude",
          status: :in_progress,
          claimed_at: at
        })
    end

    test "uses the session timezone and locale on mount", %{conn: conn, user: user} do
      seed_claim_at(user, ~U[2026-06-20 18:30:00Z])

      conn =
        Plug.Test.init_test_session(conn, %{
          "timezone" => "America/New_York",
          "locale" => "de"
        })

      # Static render: the feed loads its events once connected, so the static
      # pass renders the empty feed, already in the session's language.
      static = conn |> get(~p"/agents") |> html_response(200)
      assert static =~ "data-agent-feed"
      assert static =~ "Keine aktuelle Aktivität."

      # Connected render: 18:30 UTC is 14:30 EDT on the de 24-hour clock.
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ ">14:30</time>"
      assert html =~ ~s(title="20. Juni 2026, 14:30 EDT")
      assert html =~ ~s(datetime="2026-06-20T18:30:00Z")
      refute html =~ ">18:30</time>"
    end

    test "Agents page in zh renders localised day headers and times", %{conn: conn, user: user} do
      seed_claim_at(user, ~U[2026-06-20 18:30:00Z])

      conn =
        Plug.Test.init_test_session(conn, %{"timezone" => "Asia/Tokyo", "locale" => "zh"})

      {:ok, _view, html} = live(conn, ~p"/agents")

      # 18:30 UTC is 03:30 on June 21 in Tokyo, a Sunday.
      assert html =~ ">03:30</time>"
      assert html =~ "6月21日 (周日)"
      refute html =~ "Sun, Jun 21"
    end
  end
end
