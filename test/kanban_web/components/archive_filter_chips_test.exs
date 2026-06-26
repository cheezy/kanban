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
          on_filter_change: "filter_reason",
          assignees: [],
          assignee_filter: :all,
          assignee_menu_open: false,
          has_unassigned: false,
          on_assignee_toggle: "toggle_assignee_menu",
          on_assignee_select: "filter_assignee"
        },
        overrides
      )

    rendered_to_string(~H"""
    <ArchiveFilterChips.archive_filter_chips
      counts={@counts}
      active={@active}
      on_filter_change={@on_filter_change}
      assignees={@assignees}
      assignee_filter={@assignee_filter}
      assignee_menu_open={@assignee_menu_open}
      has_unassigned={@has_unassigned}
      on_assignee_toggle={@on_assignee_toggle}
      on_assignee_select={@on_assignee_select}
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

    test "renders the Date range decorative placeholder chip with aria-disabled" do
      html = render_chips()

      assert html =~ ~s(data-archive-filter-chip-placeholder="date-range")

      # The Goal placeholder was removed; Assignee is now an active chip.
      refute html =~ ~s(data-archive-filter-chip-placeholder="goal")
      refute html =~ ~s(data-archive-filter-chip-placeholder="assignee")

      # aria-disabled is set on the single remaining placeholder.
      assert length(Regex.scan(~r/aria-disabled="true"/, html)) == 1
    end

    test "decorative chips have no phx-click attribute" do
      html = render_chips()

      placeholders =
        Regex.scan(
          ~r/<span[^>]*data-archive-filter-chip-placeholder[^>]*>/,
          html
        )

      assert length(placeholders) == 1

      for [tag] <- placeholders do
        refute tag =~ "phx-click"
      end
    end

    test "renders the divider between reason and placeholder chips" do
      assert render_chips() =~ "data-archive-filter-divider"
    end
  end

  describe "archive_filter_chips/1 — assignee chip" do
    test "renders the Assignee chip as an active button with the toggle event" do
      html = render_chips()

      assignee_chip =
        Regex.run(~r/<button[^>]*data-archive-filter-chip="assignee"[^>]*>/, html)
        |> List.first()

      assert assignee_chip =~ ~s(phx-click="toggle_assignee_menu")
      assert assignee_chip =~ ~s(aria-expanded="false")
      assert assignee_chip =~ ~s(aria-haspopup="listbox")
      refute assignee_chip =~ "aria-disabled"
    end

    test "does not render the dropdown menu when closed" do
      refute render_chips(%{assignee_menu_open: false}) =~ "data-archive-assignee-menu"
    end

    test "renders the dropdown with an option per assignee plus 'All assignees' when open" do
      html =
        render_chips(%{
          assignee_menu_open: true,
          assignees: [%{id: 1, name: "Ada"}, %{id: 2, name: "Grace"}]
        })

      assert html =~ "data-archive-assignee-menu"
      assert html =~ ~s(data-archive-assignee-option="all")
      assert html =~ ~s(data-archive-assignee-option="1")
      assert html =~ ~s(data-archive-assignee-option="2")
      assert html =~ "All assignees"
      assert html =~ "Ada"
      assert html =~ "Grace"
    end

    test "each assignee option wires on_assignee_select with phx-value-assignee" do
      html =
        render_chips(%{
          assignee_menu_open: true,
          assignees: [%{id: 7, name: "Ada"}]
        })

      option =
        Regex.run(~r/<button[^>]*data-archive-assignee-option="7"[^>]*>/, html)
        |> List.first()

      assert option =~ ~s(phx-click="filter_assignee")
      assert option =~ ~s(phx-value-assignee="7")
    end

    test "renders the 'Unassigned' option only when has_unassigned is true" do
      with_unassigned =
        render_chips(%{assignee_menu_open: true, has_unassigned: true})

      without_unassigned =
        render_chips(%{assignee_menu_open: true, has_unassigned: false})

      assert with_unassigned =~ ~s(data-archive-assignee-option="unassigned")
      assert with_unassigned =~ "Unassigned"
      refute without_unassigned =~ ~s(data-archive-assignee-option="unassigned")
    end

    test "a selected assignee inverts the chip and shows the selected name" do
      html =
        render_chips(%{
          assignee_filter: 1,
          assignees: [%{id: 1, name: "Ada"}]
        })

      assignee_chip =
        Regex.run(
          ~r/<button[^>]*data-archive-filter-chip="assignee"[^>]*>[\s\S]*?<\/button>/,
          html
        )
        |> List.first()

      assert assignee_chip =~ "background: var(--ink)"
      assert assignee_chip =~ "color: var(--surface)"
      assert assignee_chip =~ ~s(aria-pressed="true")
      assert assignee_chip =~ "Ada"
    end

    test "no selected assignee leaves the chip un-pressed with the generic label" do
      html = render_chips(%{assignee_filter: :all})

      assignee_chip =
        Regex.run(
          ~r/<button[^>]*data-archive-filter-chip="assignee"[^>]*>[\s\S]*?<\/button>/,
          html
        )
        |> List.first()

      assert assignee_chip =~ ~s(aria-pressed="false")
      assert assignee_chip =~ "Assignee"
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

    test "renders the Date range placeholder label plus the active Assignee label" do
      html = render_chips()
      assert html =~ "Assignee"
      assert html =~ "Date range"
      # The Goal chip was removed from the filter row.
      refute html =~ ~s(data-archive-filter-chip-placeholder="goal")
    end
  end
end
