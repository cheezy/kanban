defmodule KanbanWeb.ArchiveRowTest do
  @moduledoc """
  Tests for `KanbanWeb.ArchiveRow.archive_row/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ArchiveRow

  defp user(overrides \\ %{}) do
    Map.merge(%{id: 42, name: "Jane Reviewer", email: "jane@example.com"}, overrides)
  end

  defp column(overrides \\ %{}) do
    Map.merge(%{id: 7, name: "Backlog"}, overrides)
  end

  defp task(overrides) do
    base = %{
      id: 100,
      identifier: "W101",
      title: "Wire the thing",
      type: :work,
      archive_reason: :completed,
      archive_note: nil,
      archived_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second),
      time_spent_minutes: 161,
      assigned_to: user(),
      archived_by: user(%{id: 43, name: "Bob Approver"}),
      column: column(),
      duplicate_of: nil,
      parent: nil
    }

    Map.merge(base, overrides)
  end

  defp render_row(task_overrides \\ %{}, opts \\ []) do
    assigns = %{
      task: task(task_overrides),
      on_action_menu: Keyword.get(opts, :on_action_menu, "open_archive_actions")
    }

    rendered_to_string(~H"""
    <ArchiveRow.archive_row task={@task} on_action_menu={@on_action_menu} />
    """)
  end

  describe "archive_row/1 — markers and structure" do
    test "has data-archive-row and data-archive-row-reason markers on the root" do
      html = render_row()
      assert html =~ "data-archive-row"
      assert html =~ ~s(data-archive-row-reason="completed")
    end

    test "uses the 8-column grid from the design source" do
      html = render_row()

      assert html =~
               "grid-template-columns: 20px 78px minmax(0, 1.6fr) 130px 150px 140px 150px 28px"
    end

    test "renders the type icon span" do
      assert render_row() =~ "data-archive-row-type-icon"
    end

    test "renders all expected per-cell markers" do
      html = render_row()

      for marker <- ~w(
        data-archive-row-ident
        data-archive-row-title
        data-archive-row-reason-pill
        data-archive-row-outcome
        data-archive-row-assignee
        data-archive-row-archived-by
        data-archive-row-kebab
      ) do
        assert html =~ marker
      end
    end
  end

  describe "archive_row/1 — type icons" do
    test "work tasks get the document-text icon" do
      html = render_row(%{type: :work})
      assert html =~ "hero-document-text"
    end

    test "defect tasks get the bug icon in st-blocked" do
      html = render_row(%{type: :defect})
      assert html =~ "hero-bug-ant"
      assert html =~ "color: var(--st-blocked)"
    end

    test "goal tasks get the flag icon in stride-violet" do
      html = render_row(%{type: :goal})
      assert html =~ "hero-flag"
      assert html =~ "color: var(--stride-violet)"
    end
  end

  describe "archive_row/1 — strikethrough rules" do
    test "duplicate reason strikes through identifier AND title" do
      duplicate = %{id: 99, identifier: "W41"}

      html =
        render_row(%{
          archive_reason: :duplicate,
          duplicate_of: duplicate
        })

      ident_cell =
        Regex.run(~r/<span[^>]*data-archive-row-ident[^>]*>/, html)
        |> List.first()

      title_cell =
        Regex.run(~r/<span[^>]*data-archive-row-title[^>]*>/, html)
        |> List.first()

      assert ident_cell =~ "text-decoration: line-through"
      assert title_cell =~ "text-decoration: line-through"
    end

    test "wontdo reason strikes through title but NOT identifier" do
      html =
        render_row(%{
          archive_reason: :wontdo,
          archive_note: "Out of scope for now."
        })

      ident_cell =
        Regex.run(~r/<span[^>]*data-archive-row-ident[^>]*>/, html)
        |> List.first()

      title_cell =
        Regex.run(~r/<span[^>]*data-archive-row-title[^>]*>/, html)
        |> List.first()

      refute ident_cell =~ "text-decoration: line-through"
      assert title_cell =~ "text-decoration: line-through"
    end

    test "completed reason strikes through neither" do
      html = render_row()
      ident_cell = Regex.run(~r/<span[^>]*data-archive-row-ident[^>]*>/, html) |> List.first()
      title_cell = Regex.run(~r/<span[^>]*data-archive-row-title[^>]*>/, html) |> List.first()
      refute ident_cell =~ "text-decoration: line-through"
      refute title_cell =~ "text-decoration: line-through"
    end

    test "nil archive_reason normalizes to :completed (legacy archived rows)" do
      html = render_row(%{archive_reason: nil})
      assert html =~ ~s(data-archive-row-reason="completed")
      # The reason pill displays the Completed label.
      pill =
        Regex.run(~r/<span[^>]*data-archive-row-reason-pill[^>]*>[\s\S]*?<\/span>/, html)
        |> List.first()

      assert pill =~ "Completed"
    end
  end

  describe "archive_row/1 — sub-line" do
    test "duplicate reason renders the '→ <identifier>' duplicate link" do
      html =
        render_row(%{
          archive_reason: :duplicate,
          duplicate_of: %{id: 99, identifier: "W41"}
        })

      assert html =~ "data-archive-row-duplicate-of"
      assert html =~ "→ W41"
    end

    test "parent goal renders the 'goal: <identifier>' link" do
      html =
        render_row(%{
          parent: %{id: 200, identifier: "G2"}
        })

      assert html =~ "data-archive-row-parent-goal"
      assert html =~ "G2"
    end

    test "wontdo reason renders the archive_note preview" do
      html =
        render_row(%{
          archive_reason: :wontdo,
          archive_note: "Out of scope for v1"
        })

      assert html =~ "data-archive-row-note"
      assert html =~ "Out of scope for v1"
    end

    test "completed reason with no parent and no note renders no sub-line" do
      html = render_row()
      refute html =~ "data-archive-row-sub-line"
    end

    test "wontdo reason with blank note renders no sub-line note" do
      html = render_row(%{archive_reason: :wontdo, archive_note: "   "})
      refute html =~ "data-archive-row-note"
    end
  end

  describe "archive_row/1 — reason pill" do
    test "completed reason pill uses the st-done palette" do
      html = render_row()
      pill = Regex.run(~r/<span[^>]*data-archive-row-reason-pill[^>]*>/, html) |> List.first()
      assert pill =~ "var(--st-done-soft)"
      assert pill =~ "var(--st-done)"
    end

    test "cancelled reason pill uses the st-blocked palette" do
      html = render_row(%{archive_reason: :cancelled, archive_note: "x"})
      pill = Regex.run(~r/<span[^>]*data-archive-row-reason-pill[^>]*>/, html) |> List.first()
      assert pill =~ "var(--st-blocked-soft)"
      assert pill =~ "var(--st-blocked)"
    end
  end

  describe "archive_row/1 — outcome cell" do
    test ":completed renders the cycle time with a check icon" do
      html = render_row(%{archive_reason: :completed, time_spent_minutes: 161})
      assert html =~ ~s(data-archive-row-outcome="completed")
      assert html =~ "2h 41m"
      assert html =~ "hero-check"
    end

    test ":completed with nil time_spent_minutes renders em-dash" do
      html = render_row(%{archive_reason: :completed, time_spent_minutes: nil})

      outcome =
        Regex.run(~r/<div[^>]*data-archive-row-outcome="completed"[\s\S]*?<\/div>/, html)
        |> List.first()

      assert outcome =~ "—"
    end

    test "non-completed renders 'died at <column.name>'" do
      html =
        render_row(%{
          archive_reason: :wontdo,
          archive_note: "x",
          column: column(%{name: "Backlog"})
        })

      assert html =~ ~s(data-archive-row-outcome="died")
      assert html =~ "died at"
      assert html =~ "Backlog"
    end

    test "non-completed with unloaded column renders 'died at unknown'" do
      html =
        render_row(%{
          archive_reason: :wontdo,
          archive_note: "x",
          column: %Ecto.Association.NotLoaded{}
        })

      assert html =~ "unknown"
    end
  end

  describe "archive_row/1 — assignee cell" do
    test "renders avatar + name when assigned_to is loaded" do
      html = render_row(%{assigned_to: user(%{name: "Jane Doe"})})
      assert html =~ "data-archive-row-assignee"
      assert html =~ "Jane Doe"
    end

    test "renders em-dash when assigned_to is nil" do
      html = render_row(%{assigned_to: nil})
      assert html =~ "data-archive-row-assignee-empty"
      # The non-empty marker (data-archive-row-assignee) is a strict
      # prefix of the empty marker, so use a regex with a non-hyphen
      # boundary to confirm only the empty variant is present.
      refute Regex.match?(~r/data-archive-row-assignee[^-]/, html)
    end

    test "treats Ecto.Association.NotLoaded the same as nil" do
      html = render_row(%{assigned_to: %Ecto.Association.NotLoaded{}})
      assert html =~ "data-archive-row-assignee-empty"
    end
  end

  describe "archive_row/1 — kebab" do
    test "wires phx-click to :on_action_menu with phx-value-id" do
      html = render_row(%{}, on_action_menu: "open_actions")
      kebab = Regex.run(~r/<button[^>]*data-archive-row-kebab[^>]*>/, html) |> List.first()
      assert kebab =~ ~s(phx-click="open_actions")
      assert kebab =~ ~s(phx-value-id="100")
    end

    test "has an accessible label" do
      html = render_row()
      kebab = Regex.run(~r/<button[^>]*data-archive-row-kebab[^>]*>/, html) |> List.first()
      assert kebab =~ ~s(aria-label="Open archive actions")
    end
  end

  describe "archive_row/1 — archived-by" do
    test "renders 'by <name>' from the archived_by user" do
      html = render_row(%{archived_by: user(%{name: "Bob Approver"})})
      assert html =~ "by"
      assert html =~ "Bob Approver"
    end

    test "renders only the date when archived_by is not loaded" do
      html = render_row(%{archived_by: %Ecto.Association.NotLoaded{}})
      assert html =~ "data-archive-row-archived-by"
      refute html =~ " by "
    end
  end
end
