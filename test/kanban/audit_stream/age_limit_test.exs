defmodule Kanban.AuditStream.AgeLimitTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.Adapters.Datadog
  alias Kanban.AuditStream.Adapters.Https
  alias Kanban.AuditStream.Adapters.SplunkHec
  alias Kanban.AuditStream.AgeLimit

  test "threshold/2 is 17 hours back for Datadog and nil for kinds that accept any age" do
    now = ~U[2026-11-12 18:00:00Z]

    assert AgeLimit.threshold(Datadog, now) == ~U[2026-11-12 01:00:00Z]
    assert AgeLimit.threshold(Https, now) == nil
    assert AgeLimit.threshold(SplunkHec, now) == nil
  end
end
