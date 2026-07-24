defmodule KanbanWeb.BoardsNavStripTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.BoardsNavStrip
  alias KanbanWeb.Layouts

  defp render_strip(opts \\ []) do
    assigns = %{active: Keyword.get(opts, :active)}

    rendered_to_string(~H"""
    <BoardsNavStrip.boards_nav_strip active={@active} />
    """)
  end

  describe "boards_nav_strip/1 — links" do
    test "renders exactly three links" do
      html = render_strip()

      assert html |> String.split("<a ") |> length() == 4
    end

    test "renders the three workspace destinations with their hrefs" do
      html = render_strip()

      assert html =~ ~s(href="/agents")
      assert html =~ ~s(href="/review")
      assert html =~ ~s(href="/metrics")
    end

    test "links to the workspace metrics page, never the per-board dashboard" do
      html = render_strip()

      assert html =~ ~s(href="/metrics")
      refute html =~ "/boards/"
    end

    test "does not link back to the Boards index it sits on" do
      refute render_strip() =~ ~s(href="/boards")
    end

    test "renders the gettext labels" do
      html = render_strip()

      assert html =~ ~r/>\s*Agents\s*</
      assert html =~ ~r/>\s*Review queue\s*</
      assert html =~ ~r/>\s*Metrics\s*</
    end

    test "renders the destinations in Agents, Review queue, Metrics order" do
      html = render_strip()

      positions =
        Enum.map(~w(/agents /review /metrics), fn path ->
          {pos, _len} = :binary.match(html, ~s(href="#{path}"))
          pos
        end)

      assert positions == Enum.sort(positions)
    end
  end

  describe "boards_nav_strip/1 — canonical source" do
    test "labels and paths come from Layouts.primary_nav_items/1, not local literals" do
      html = render_strip()

      canonical =
        Layouts.primary_nav_items()
        |> Enum.filter(&(&1.id in [:agents, :review, :metrics]))

      assert length(canonical) == 3

      for item <- canonical do
        assert html =~ ~s(href="#{item.path}")
        assert html =~ item.label
        assert html =~ item.icon
      end
    end

    test "labels are actually translated, not hardcoded English" do
      Gettext.put_locale(KanbanWeb.Gettext, "fr")
      on_exit(fn -> Gettext.put_locale(KanbanWeb.Gettext, "en") end)

      html = render_strip()

      refute html =~ ~r/>\s*Review queue\s*</
      assert html =~ ~s(href="/review")
    end
  end

  describe "boards_nav_strip/1 — active state" do
    test "marks no link active by default, as on the Boards index" do
      html = render_strip()

      refute html =~ ~s(aria-current="page")
      refute html =~ "2px solid var(--stride-orange)"
      assert html =~ "2px solid transparent"
    end

    test "marks the matching link active when one is given" do
      html = render_strip(active: :review)

      assert html =~ ~s(aria-current="page")
      assert html =~ "2px solid var(--stride-orange)"
    end

    test "an unknown active atom marks nothing active" do
      html = render_strip(active: :nope)

      refute html =~ ~s(aria-current="page")
    end
  end

  describe "boards_nav_strip/1 — theming" do
    test "uses only theme-aware custom properties" do
      html = render_strip(active: :agents)

      assert html =~ "var(--line)"
      assert html =~ "var(--ink-3)"
      assert html =~ "var(--ink-4)"
      assert html =~ "var(--stride-orange)"

      refute html =~ "#fff"
      refute html =~ "gray-"
      refute html =~ "bg-white"
    end

    test "omits BoardTabs' full-bleed bar chrome, which would double the index's padding" do
      html = render_strip()

      refute html =~ "padding: 0 22px;"
      refute html =~ "background: var(--surface);"
      refute html =~ "flex-shrink: 0;"
      # The border-bottom stays: the active underline sits on it.
      assert html =~ "border-bottom: 1px solid var(--line);"
    end
  end
end
