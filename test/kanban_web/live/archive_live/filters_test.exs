defmodule KanbanWeb.ArchiveLive.FiltersTest do
  @moduledoc """
  Unit tests for the pure archive filter/coercion helpers extracted from
  `KanbanWeb.ArchiveLive.Index`.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task
  alias KanbanWeb.ArchiveLive.Filters

  defp task(attrs), do: struct(%Task{title: "Task"}, attrs)

  describe "apply_reason/2" do
    test ":all returns every row" do
      rows = [task(archive_reason: :completed), task(archive_reason: :cancelled)]
      assert Filters.apply_reason(rows, :all) == rows
    end

    test ":completed includes legacy nil-reason rows and excludes others" do
      completed = task(archive_reason: :completed)
      legacy = task(archive_reason: nil)
      cancelled = task(archive_reason: :cancelled)

      result = Filters.apply_reason([completed, legacy, cancelled], :completed)
      assert completed in result
      assert legacy in result
      refute cancelled in result
    end
  end

  describe "apply_assignee/2" do
    test ":all returns every row" do
      rows = [task(assigned_to: %{id: 1}), task(assigned_to: nil)]
      assert Filters.apply_assignee(rows, :all) == rows
    end

    test ":unassigned keeps only nil-assignee rows" do
      assigned = task(assigned_to: %{id: 1})
      unassigned = task(assigned_to: nil)
      assert Filters.apply_assignee([assigned, unassigned], :unassigned) == [unassigned]
    end

    test "an integer id keeps only that user's rows" do
      a = task(assigned_to: %{id: 1})
      b = task(assigned_to: %{id: 2})
      assert Filters.apply_assignee([a, b], 1) == [a]
    end
  end

  describe "apply_search/2" do
    test "a blank query returns every row" do
      rows = [task(title: "Deploy"), task(title: "Docs")]
      assert Filters.apply_search(rows, "") == rows
    end

    test "matches titles case-insensitively by substring" do
      deploy = task(title: "Deploy Pipeline")
      docs = task(title: "Write Docs")
      assert Filters.apply_search([deploy, docs], "deploy") == [deploy]
    end

    test "a query matching nothing yields an empty list" do
      assert Filters.apply_search([task(title: "Deploy")], "zzz") == []
    end
  end

  describe "apply_date_range/3" do
    test "both nil is a no-op" do
      rows = [task(archived_at: ~U[2026-01-10 12:00:00Z])]
      assert Filters.apply_date_range(rows, nil, nil) == rows
    end

    test "is inclusive of the from/to boundary dates" do
      on_from = task(archived_at: ~U[2026-01-10 23:59:59Z])
      mid = task(archived_at: ~U[2026-01-15 00:00:00Z])
      on_to = task(archived_at: ~U[2026-01-20 00:00:01Z])
      outside = task(archived_at: ~U[2026-02-01 00:00:00Z])

      result =
        Filters.apply_date_range([on_from, mid, on_to, outside], ~D[2026-01-10], ~D[2026-01-20])

      assert result == [on_from, mid, on_to]
    end

    test "open-ended bounds and nil archived_at exclusion" do
      early = task(archived_at: ~U[2026-01-10 12:00:00Z])
      late = task(archived_at: ~U[2026-01-20 12:00:00Z])
      undated = task(archived_at: nil)

      # Only a lower bound; the nil-archived_at row is excluded when a bound is set.
      assert Filters.apply_date_range([early, late, undated], ~D[2026-01-15], nil) == [late]
    end
  end

  describe "reason_matches?/2" do
    test "a nil reason matches :completed" do
      assert Filters.reason_matches?(%{archive_reason: nil}, :completed)
      refute Filters.reason_matches?(%{archive_reason: :cancelled}, :completed)
    end
  end

  describe "parse_reason/1" do
    test "coerces known reasons and 'all'" do
      assert Filters.parse_reason("all") == :all
      assert Filters.parse_reason("completed") == :completed
    end

    @tag :capture_log
    test "an unknown reason degrades to :all" do
      assert Filters.parse_reason("bogus") == :all
      assert Filters.parse_reason(nil) == :all
    end
  end

  describe "parse_assignee/1" do
    test "coerces sentinels, ids, and bad input" do
      assert Filters.parse_assignee("all") == :all
      assert Filters.parse_assignee("unassigned") == :unassigned
      assert Filters.parse_assignee("42") == 42
      assert Filters.parse_assignee("42x") == :all
      assert Filters.parse_assignee(nil) == :all
    end
  end

  describe "parse_date/1" do
    test "parses ISO dates and degrades invalid input to nil" do
      assert Filters.parse_date("2026-01-15") == ~D[2026-01-15]
      assert Filters.parse_date("") == nil
      assert Filters.parse_date("not-a-date") == nil
      assert Filters.parse_date(nil) == nil
    end
  end
end
