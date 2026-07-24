defmodule KanbanWeb.BoardsHeaderTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.BoardsHeader

  defp metrics(overrides \\ %{}) do
    Map.merge(%{open: 5, doing: 4, review: 2, done: 142}, overrides)
  end

  defp render_header(opts \\ []) do
    assigns = %{
      metrics: Keyword.get(opts, :metrics, metrics()),
      members: Keyword.get(opts, :members, [])
    }

    rendered_to_string(~H"""
    <BoardsHeader.boards_header metrics={@metrics} members={@members} />
    """)
  end

  # kv/1 renders one <div> whose only children are <span>s, so a non-greedy
  # match up to the first </div> isolates exactly one stat card. Without this
  # the four cards are indistinguishable whenever two of them share a value.
  defp kv_card(html, marker) do
    [card] = Regex.run(~r/<div data-boards-header-kv="#{marker}".*?<\/div>/s, html)
    card
  end

  defp human(name, palette \\ "human-green") do
    %{kind: :human, name: name, palette: palette, user_id: :erlang.phash2(name)}
  end

  defp agent(name, palette \\ "agent-claude") do
    %{kind: :agent, name: name, palette: palette}
  end

  describe "boards_header/1 — structure" do
    test "outermost element carries the data-boards-header marker" do
      # Anchored on an attribute boundary so the kv/divider/members markers,
      # which all share this prefix, cannot satisfy the assertion.
      assert render_header() =~ ~r/data-boards-header[\s>]/
    end

    test "right-aligns itself so it drops into the index title row" do
      html = render_header()

      assert html =~ "margin-left: auto;"
      assert html =~ "flex-wrap: wrap;"
    end

    test "renders the four stat cards in To Do, Doing, Review, Done order" do
      html = render_header()

      positions =
        Enum.map(~w(to-do doing review done), fn marker ->
          {pos, _len} = :binary.match(html, ~s(data-boards-header-kv="#{marker}"))
          pos
        end)

      assert positions == Enum.sort(positions)
    end
  end

  describe "boards_header/1 — status counts" do
    test "renders each aggregated count in its own stat card" do
      html = render_header()

      assert kv_card(html, "to-do") =~ ~r/>\s*5\s*</
      assert kv_card(html, "doing") =~ ~r/>\s*4\s*</
      assert kv_card(html, "review") =~ ~r/>\s*2\s*</
      assert kv_card(html, "done") =~ ~r/>\s*142\s*</
    end

    test "renders the four labels through gettext" do
      html = render_header()

      assert kv_card(html, "to-do") =~ "To Do"
      assert kv_card(html, "doing") =~ "Doing"
      assert kv_card(html, "review") =~ "Review"
      assert kv_card(html, "done") =~ "Done"
      assert html =~ ~s(class="ucase")
    end

    test "labels are actually translated, not hardcoded English" do
      Gettext.put_locale(KanbanWeb.Gettext, "fr")
      on_exit(fn -> Gettext.put_locale(KanbanWeb.Gettext, "en") end)

      html = render_header()

      assert kv_card(html, "to-do") =~ "À faire"
      assert kv_card(html, "doing") =~ "En cours"
      refute kv_card(html, "to-do") =~ "To Do"
    end

    test "applies the matching status tone token to each card" do
      html = render_header()

      assert kv_card(html, "to-do") =~ "color: var(--ink);"
      assert kv_card(html, "doing") =~ "color: var(--st-doing);"
      assert kv_card(html, "review") =~ "color: var(--st-review);"
      assert kv_card(html, "done") =~ "color: var(--st-done);"
    end

    test "renders zeros for an all-zero metrics map" do
      html = render_header(metrics: %{open: 0, doing: 0, review: 0, done: 0})

      for marker <- ~w(to-do doing review done) do
        assert kv_card(html, marker) =~ ~r/>\s*0\s*</
      end
    end

    test "falls back to 0 for every key missing from the metrics map" do
      html = render_header(metrics: %{})

      for marker <- ~w(to-do doing review done) do
        assert kv_card(html, marker) =~ ~r/>\s*0\s*</
      end
    end

    test "treats a nil metric value as 0" do
      html = render_header(metrics: metrics(%{doing: nil}))

      assert kv_card(html, "doing") =~ ~r/>\s*0\s*</
      assert kv_card(html, "to-do") =~ ~r/>\s*5\s*</
    end

    test "renders zeros when metrics is not a map at all" do
      # attr :metrics, :map only checks literals at compile time, so a dynamic
      # assign can still arrive as a non-map. The header degrades, not crashes.
      html = render_header(metrics: "not a map")

      for marker <- ~w(to-do doing review done) do
        assert kv_card(html, marker) =~ ~r/>\s*0\s*</
      end
    end

    test "renders very large counts without truncation" do
      html = render_header(metrics: metrics(%{done: 1_234_567}))

      assert kv_card(html, "done") =~ "1234567"
      # HEEx escapes the single quotes around the tnum feature name.
      assert html =~ "font-feature-settings: &#39;tnum&#39;;"
    end
  end

  describe "boards_header/1 — member stack" do
    test "renders the avatar stack when members are present" do
      html = render_header(members: [human("Ada"), agent("Claude")])

      assert html =~ "data-boards-header-members"
      assert html =~ "background: oklch(60% 0.10 155);"
      assert html =~ "background: oklch(70% 0.16 47);"
    end

    test "renders humans as circles and agents as squares in one stack" do
      html = render_header(members: [human("Ada"), agent("Claude")])

      assert html =~ "border-radius: 50%;"
      assert html =~ "border-radius: 4px;"
    end

    test "still renders a member that carries no palette" do
      # Avatar falls back to a var(--ink-3) chip. The context never produces
      # this shape, but a hand-built list can, so pin that it renders rather
      # than raising. See the :members attr doc for the contrast caveat.
      html = render_header(members: [%{kind: :human, name: "Ada"}])

      assert html =~ "data-boards-header-members"
      assert html =~ "background: var(--ink-3);"
    end

    test "renders the divider alongside the stack" do
      html = render_header(members: [human("Ada")])

      assert html =~ "data-boards-header-divider"
      assert html =~ "background: var(--line);"
    end

    test "hides the stack and the divider when members is empty" do
      html = render_header(members: [])

      refute html =~ "data-boards-header-members"
      refute html =~ "data-boards-header-divider"

      assert kv_card(html, "to-do") =~ ~r/>\s*5\s*</
    end

    test "hides the stack and the divider when members is nil" do
      html = render_header(members: nil)

      refute html =~ "data-boards-header-members"
      refute html =~ "data-boards-header-divider"
    end

    test "renders the +N overflow chip when the roster exceeds the visible cap" do
      members = Enum.map(1..11, &human("Person #{&1}"))

      html = render_header(members: members)

      assert html =~ ~r/>\s*\+3\s*</
    end

    test "does not render an overflow chip at exactly the visible cap" do
      members = Enum.map(1..8, &human("Person #{&1}"))

      html = render_header(members: members)

      refute html =~ ~r/>\s*\+\d/
    end
  end

  describe "boards_header/1 — theming" do
    test "uses only theme-aware custom properties for its own chrome" do
      html = render_header()

      assert html =~ "var(--ink)"
      assert html =~ "var(--st-doing)"
      assert html =~ "var(--st-review)"
      assert html =~ "var(--st-done)"

      refute html =~ "#fff"
      refute html =~ "gray-"
      refute html =~ "bg-white"
    end
  end

  describe "boards_header/1 — escaping" do
    test "escapes member names instead of emitting raw markup" do
      html = render_header(members: [human("<script>alert(1)</script>")])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
