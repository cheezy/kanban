defmodule Kanban.AuditStream.StartPointTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.StartPoint

  test "options/1 offers Datadog only now and 17h" do
    assert StartPoint.options(:datadog) == ~w(now 17h)
    assert StartPoint.options(:splunk_hec) == ~w(now 24h 7d all)
    assert StartPoint.options(:https) == ~w(now 24h 7d all)
    assert StartPoint.options(:unknown) == []
  end

  test "pop/1 takes start_from from either key and defaults to now" do
    assert StartPoint.pop(%{"start_from" => "7d", "name" => "N"}) == {"7d", %{"name" => "N"}}
    assert StartPoint.pop(%{start_from: :all, name: "N"}) == {"all", %{name: "N"}}
    assert StartPoint.pop(name: "N") == {"now", %{name: "N"}}
  end

  test "validate/2 refuses a start point the kind does not offer" do
    datadog = Ecto.Changeset.change(%Destination{kind: :datadog})

    assert StartPoint.validate(datadog, "17h").valid?
    refute StartPoint.validate(datadog, "24h").valid?
    refute StartPoint.validate(datadog, 7).valid?
    no_kind = Ecto.Changeset.change(%Destination{})
    assert StartPoint.validate(no_kind, "1y").valid?
  end

  test "cursor_attrs/2 puts now at the horizon and windows at (0, 0) with not_before" do
    assert StartPoint.cursor_attrs("now", 42) == %{last_txid: 42, last_event_id: 0}
    assert StartPoint.cursor_attrs("all", 42) == %{last_txid: 0, last_event_id: 0}

    for {window, seconds} <- [{"24h", 86_400}, {"7d", 604_800}, {"17h", 61_200}] do
      assert %{last_txid: 0, last_event_id: 0, not_before: not_before} =
               StartPoint.cursor_attrs(window, 42)

      assert_in_delta DateTime.diff(not_before, DateTime.utc_now()), -seconds, 5
    end
  end
end
