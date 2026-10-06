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
end
