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
            completed: 5,
            cancelled: 2,
            wontdo: 1,
            duplicate: 2,
            deferred: 0
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

    test "renders one active chip per reason plus All" do
      html = render_chips()

      for marker <- ~w(all completed cancelled wontdo duplicate deferred) do
        assert html =~ ~s(data-archive-filter-chip="#{marker}")
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
          counts: %{all: 99, completed: 7, cancelled: 3, wontdo: 4, duplicate: 1, deferred: 2}
        })

      # Each reason chip has '· N' suffix from the count span.
      assert html =~ ~r/Completed[\s\S]*?·\s*7/
      assert html =~ ~r/Cancelled[\s\S]*?·\s*3/
      assert html =~ ~r/Won&#39;t do[\s\S]*?·\s*4/
      assert html =~ ~r/Duplicate[\s\S]*?·\s*1/
      assert html =~ ~r/Deferred[\s\S]*?·\s*2/
    end

    test "treats missing reason keys as zero" do
      html = render_chips(%{counts: %{all: 0}})
      # Five reasons each with `· 0` — at least 5 occurrences.
      assert length(Regex.scan(~r/·\s*0/, html)) >= 5
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
      assert all_chip =~ "color: white"
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

    test "non-active Cancelled chip uses st-blocked palette" do
      html = render_chips(%{active: :all})

      cancelled_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="cancelled"[^>]*>/, html)
        |> List.first()

      assert cancelled_chip =~ "background: var(--st-blocked-soft)"
      assert cancelled_chip =~ "color: var(--st-blocked)"
    end

    test "non-active Deferred chip uses st-review palette" do
      html = render_chips(%{active: :all})

      deferred_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="deferred"[^>]*>/, html)
        |> List.first()

      assert deferred_chip =~ "background: var(--st-review-soft)"
      assert deferred_chip =~ "color: var(--st-review)"
    end

    test "neutral Won't do and Duplicate chips use the surface palette" do
      html = render_chips(%{active: :all})

      for marker <- ["wontdo", "duplicate"] do
        chip =
          Regex.run(~r/<button[^>]*data-archive-filter-chip="#{marker}"[^>]*>/, html)
          |> List.first()

        assert chip =~ "background: var(--surface)"
        assert chip =~ "color: var(--ink-2)"
      end
    end
  end

  describe "archive_filter_chips/1 — phx wiring" do
    test "each active chip wires phx-click to :on_filter_change with phx-value-reason" do
      html = render_chips(%{on_filter_change: "filter_reason"})

      for {marker, value} <- [
            {"all", "all"},
            {"completed", "completed"},
            {"cancelled", "cancelled"},
            {"wontdo", "wontdo"},
            {"duplicate", "duplicate"},
            {"deferred", "deferred"}
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
    test "renders the six reason labels (English)" do
      html = render_chips()
      assert html =~ "All"
      assert html =~ "Completed"
      assert html =~ "Cancelled"
      # HTML-escapes the apostrophe.
      assert html =~ "Won&#39;t do"
      assert html =~ "Duplicate"
      assert html =~ "Deferred"
    end

    test "renders the three placeholder labels" do
      html = render_chips()
      assert html =~ "Goal"
      assert html =~ "Assignee"
      assert html =~ "Date range"
    end
  end
end
