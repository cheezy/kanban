defmodule Kanban.AuditLog.FiltersTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Filters
  alias Kanban.AuditLog.Query

  describe "parse/1" do
    test "parses every accepted param into filters and normalized params" do
      cursor =
        Query.encode_cursor(%AuditEvent{id: 7, inserted_at: ~U[2026-10-01 12:00:00.000001Z]})

      parsed =
        Filters.parse(%{
          "action" => "login_failed",
          "actor_email" => "  Admin@Example.com ",
          "from" => "2026-10-01",
          "to" => "2026-10-03",
          "cursor" => cursor
        })

      assert parsed.filters == [
               action: "login_failed",
               actor_email: "Admin@Example.com",
               since: ~U[2026-10-01 00:00:00.000000Z],
               until: ~U[2026-10-04 00:00:00.000000Z]
             ]

      assert parsed.cursor == {~U[2026-10-01 12:00:00.000001Z], 7}

      assert parsed.params == %{
               "action" => "login_failed",
               "actor_email" => "Admin@Example.com",
               "from" => "2026-10-01",
               "to" => "2026-10-03",
               "cursor" => cursor
             }
    end

    test "the to-date covers its whole UTC day (exclusive bound is the next midnight)" do
      %{filters: filters} = Filters.parse(%{"to" => "2026-12-31"})
      assert filters[:until] == ~U[2027-01-01 00:00:00.000000Z]
    end

    test "drops blank and missing params" do
      parsed = Filters.parse(%{"action" => "", "actor_email" => "   ", "from" => "", "to" => nil})

      assert Enum.all?(parsed.filters, fn {_key, value} -> is_nil(value) end)
      assert parsed.cursor == nil
      assert parsed.params == %{}
    end

    test "drops an action that is not a well-formed action name, never creating atoms" do
      for bad <- [
            "Login",
            "login failed",
            "x; DROP TABLE audit_events",
            "1abc",
            String.duplicate("a", 65)
          ] do
        parsed = Filters.parse(%{"action" => bad})
        assert parsed.filters[:action] == nil, "expected #{inspect(bad)} to be rejected"
        refute Map.has_key?(parsed.params, "action")
      end

      assert Filters.parse(%{"action" => "never_seen_action_xyz"}).filters[:action] ==
               "never_seen_action_xyz"
    end

    test "drops invalid dates instead of raising" do
      for bad <- ["2026-13-01", "yesterday", "2026-02-30", "'; --"] do
        parsed = Filters.parse(%{"from" => bad, "to" => bad})
        assert parsed.filters[:since] == nil
        assert parsed.filters[:until] == nil
        assert parsed.params == %{}
      end
    end

    test "drops dates outside years 1..9999, which the database cannot bind" do
      for bad <- ["-4713-01-01", "-0001-01-01", "0000-12-31", "+10000-01-01"] do
        parsed = Filters.parse(%{"from" => bad, "to" => bad})
        assert parsed.filters[:since] == nil, "expected #{bad} to be rejected"
        assert parsed.filters[:until] == nil
        assert parsed.params == %{}
      end

      %{filters: filters} = Filters.parse(%{"from" => "0001-01-01", "to" => "9999-12-31"})
      assert filters[:since] == ~U[0001-01-01 00:00:00.000000Z]
      assert DateTime.compare(filters[:until], ~U[9999-12-31 00:00:00.000000Z]) == :gt
    end

    test "drops an over-long or invalid email" do
      long = String.duplicate("a", 250) <> "@x.io"
      assert Filters.parse(%{"actor_email" => long}).filters[:actor_email] == nil
      assert Filters.parse(%{"actor_email" => <<0xFF, 0xFE>>}).filters[:actor_email] == nil
      assert Filters.parse(%{"actor_email" => "a\0b@x.io"}).filters[:actor_email] == nil
    end

    test "drops a tampered cursor and keeps the other filters" do
      parsed = Filters.parse(%{"cursor" => "not-a-cursor", "action" => "login_failed"})

      assert parsed.cursor == nil
      assert parsed.params == %{"action" => "login_failed"}
    end

    test "ignores non-string values and unknown keys" do
      parsed = Filters.parse(%{"action" => ["a"], "from" => %{}, "evil" => "x"})
      assert parsed.params == %{}
    end

    test "treats a non-map as no params" do
      assert Filters.parse(nil).params == %{}
    end
  end

  describe "summary/1" do
    test "returns the applied filters without the cursor" do
      cursor = Query.encode_cursor(%AuditEvent{id: 1, inserted_at: ~U[2026-10-01 00:00:00Z]})
      parsed = Filters.parse(%{"action" => "login_failed", "cursor" => cursor})

      assert Filters.summary(parsed) == %{"action" => "login_failed"}
    end
  end
end
