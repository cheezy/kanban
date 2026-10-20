defmodule Kanban.AuditLog.QueryTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Query

  describe "encode_cursor/1 and decode_cursor/1" do
    test "round-trip an event's position with microsecond precision" do
      event = %AuditEvent{id: 42, inserted_at: ~U[2026-10-05 08:09:10.123456Z]}

      cursor = Query.encode_cursor(event)

      assert cursor =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert Query.decode_cursor(cursor) == {~U[2026-10-05 08:09:10.123456Z], 42}
    end

    test "return nil for anything malformed or tampered with" do
      encode = &Base.url_encode64(&1, padding: false)

      for bad <- [
            nil,
            "",
            123,
            "%%%",
            encode.("abc"),
            encode.("1:2:3"),
            encode.("1x:2"),
            encode.("1:2x"),
            encode.("1:0"),
            encode.("1:-5"),
            encode.("1:99999999999999999999"),
            encode.("999999999999999999999:1"),
            encode.("-200000000000000000:1"),
            encode.("-62167219200000001:1"),
            String.duplicate("A", 65)
          ] do
        assert Query.decode_cursor(bad) == nil, "expected #{inspect(bad)} to decode to nil"
      end
    end
  end

  describe "matches?/2" do
    @row %{
      action: "org_audit_log_exported",
      organization_id: 7,
      actor_user_id: 3,
      inserted_at: ~U[2026-10-05 12:00:00.000000Z]
    }

    test "no filters, nil filters and a cursor all match" do
      assert Query.matches?([], @row)
      assert Query.matches?([action: nil, since: nil, until: nil], @row)
      assert Query.matches?([cursor: {~U[2000-01-01 00:00:00Z], 1}], @row)
    end

    test "action matches as a string or an atom, and only that action" do
      assert Query.matches?([action: "org_audit_log_exported"], @row)
      assert Query.matches?([action: :org_audit_log_exported], @row)
      refute Query.matches?([action: "organization_updated"], @row)
    end

    test "organization_id and actor_user_id compare exactly" do
      assert Query.matches?([organization_id: 7, actor_user_id: 3], @row)
      refute Query.matches?([organization_id: 8], @row)
      refute Query.matches?([actor_user_id: 4], @row)
    end

    test "since is inclusive and until is exclusive" do
      at = @row.inserted_at

      assert Query.matches?([since: at], @row)
      refute Query.matches?([since: DateTime.add(at, 1, :microsecond)], @row)
      refute Query.matches?([until: at], @row)
      assert Query.matches?([until: DateTime.add(at, 1, :microsecond)], @row)
    end

    test "raises on actor_email and on an unknown filter key" do
      assert_raise ArgumentError, fn -> Query.matches?([actor_email: "a@b.c"], @row) end
      assert_raise FunctionClauseError, fn -> Query.matches?([no_such_filter: 1], @row) end
    end
  end
end
