defmodule KanbanWeb.ArchiveFilterChipsTest do
  @moduledoc """
  Tests for `KanbanWeb.ArchiveFilterChips.archive_filter_chips/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ArchiveFilterChips

  defp render_chips(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          counts: %{
            all: 10,
            completed: 5
          },
          active: :all,
          on_filter_change: "filter_reason"
        },
        overrides
      )

    rendered_to_string(~H"""
    <ArchiveFilterChips.archive_filter_chips
      counts={@counts}
      active={@active}
      on_filter_change={@on_filter_change}
    />
    """)
  end

  describe "archive_filter_chips/1 — markers and structure" do
    test "renders the data-archive-filter-chips marker on the root" do
      assert render_chips() =~ "data-archive-filter-chips"
    end

    test "renders the All and Completed chips" do
      html = render_chips()

      for marker <- ~w(all completed) do
        assert html =~ ~s(data-archive-filter-chip="#{marker}")
      end
    end

    test "does not render the removed reason chips" do
      html = render_chips()

      for marker <- ~w(cancelled wontdo duplicate deferred) do
        refute html =~ ~s(data-archive-filter-chip="#{marker}")
      end
    end

    test "renders the three decorative placeholder chips with aria-disabled" do
      html = render_chips()

      for marker <- ~w(goal assignee date-range) do
        assert html =~ ~s(data-archive-filter-chip-placeholder="#{marker}")
      end

      # aria-disabled is set on every placeholder (3 instances).
      assert length(Regex.scan(~r/aria-disabled="true"/, html)) == 3
    end

    test "decorative chips have no phx-click attribute" do
      html = render_chips()

      placeholders =
        Regex.scan(
          ~r/<span[^>]*data-archive-filter-chip-placeholder[^>]*>/,
          html
        )

      assert length(placeholders) == 3

      for [tag] <- placeholders do
        refute tag =~ "phx-click"
      end
    end

    test "renders the divider between reason and placeholder chips" do
      assert render_chips() =~ "data-archive-filter-divider"
    end
  end

  describe "archive_filter_chips/1 — counts" do
    test "renders each reason chip with its count from the map" do
      html =
        render_chips(%{
          counts: %{all: 99, completed: 7}
        })

      # The Completed reason chip has a '· N' suffix from the count span.
      assert html =~ ~r/Completed[\s\S]*?·\s*7/
    end

    test "treats missing reason keys as zero" do
      html = render_chips(%{counts: %{all: 0}})
      # The single Completed reason chip renders `· 0`.
      assert html =~ ~r/·\s*0/
    end

    test "the All chip does NOT render a count suffix" do
      html = render_chips(%{counts: %{all: 99}})

      all_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="all"[\s\S]*?<\/button>/, html)
        |> List.first()

      refute all_chip =~ "·"
      refute all_chip =~ "99"
    end
  end

  describe "archive_filter_chips/1 — active styling" do
    test "active=:all inverts the All chip to ink-bg / white-fg" do
      html = render_chips(%{active: :all})

      all_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="all"[^>]*>/, html)
        |> List.first()

      assert all_chip =~ ~s(aria-pressed="true")
      assert all_chip =~ "background: var(--ink)"
      # W907: fg switched from "white" to var(--surface) so the chip stays
      # readable in dark mode (where --ink flips to near-white and white-on-
      # near-white was invisible).
      assert all_chip =~ "color: var(--surface)"
    end

    test "active=:completed inverts the Completed chip and leaves All un-pressed" do
      html = render_chips(%{active: :completed})

      completed_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="completed"[^>]*>/, html)
        |> List.first()

      all_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="all"[^>]*>/, html)
        |> List.first()

      assert completed_chip =~ ~s(aria-pressed="true")
      assert all_chip =~ ~s(aria-pressed="false")
    end

    test "non-active reason chips use their tone palette (Completed → st-done-soft)" do
      html = render_chips(%{active: :all})

      completed_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="completed"[^>]*>/, html)
        |> List.first()

      assert completed_chip =~ "background: var(--st-done-soft)"
      assert completed_chip =~ "color: var(--st-done)"
    end
  end

  describe "archive_filter_chips/1 — phx wiring" do
    test "each active chip wires phx-click to :on_filter_change with phx-value-reason" do
      html = render_chips(%{on_filter_change: "filter_reason"})

      for {marker, value} <- [
            {"all", "all"},
            {"completed", "completed"}
          ] do
        chip =
          Regex.run(~r/<button[^>]*data-archive-filter-chip="#{marker}"[^>]*>/, html)
          |> List.first()

        assert chip =~ ~s(phx-click="filter_reason")
        assert chip =~ ~s(phx-value-reason="#{value}")
      end
    end
  end

  describe "archive_filter_chips/1 — labels" do
    test "renders the All and Completed labels (English)" do
      html = render_chips()
      assert html =~ "All"
      assert html =~ "Completed"
      refute html =~ "Cancelled"
      # HTML-escapes the apostrophe.
      refute html =~ "Won&#39;t do"
      refute html =~ "Duplicate"
      refute html =~ "Deferred"
    end

    test "renders the three placeholder labels" do
      html = render_chips()
      assert html =~ "Goal"
      assert html =~ "Assignee"
      assert html =~ "Date range"
    end
  end
end
