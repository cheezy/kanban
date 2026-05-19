defmodule KanbanWeb.TelemetryTest do
  use ExUnit.Case, async: true

  describe "metrics/0" do
    test "registers the review.fallback_used counter" do
      assert Enum.any?(KanbanWeb.Telemetry.metrics(), fn metric ->
               metric.name == [:kanban, :review, :fallback_used, :count] and
                 metric.__struct__ == Telemetry.Metrics.Counter
             end)
    end

    test "registers the review.structured_used counter" do
      assert Enum.any?(KanbanWeb.Telemetry.metrics(), fn metric ->
               metric.name == [:kanban, :review, :structured_used, :count] and
                 metric.__struct__ == Telemetry.Metrics.Counter
             end)
    end
  end

  describe "review telemetry events" do
    test "[:kanban, :review, :fallback_used] event fires when invoked" do
      test_pid = self()
      handler_id = "review-fallback-used-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :review, :fallback_used],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute([:kanban, :review, :fallback_used], %{count: 1}, %{reason: "no_json"})

      assert_receive {:telemetry_event, [:kanban, :review, :fallback_used], %{count: 1},
                      %{reason: "no_json"}}

      :telemetry.detach(handler_id)
    end

    test "[:kanban, :review, :structured_used] event fires when invoked" do
      test_pid = self()
      handler_id = "review-structured-used-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :review, :structured_used],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute([:kanban, :review, :structured_used], %{count: 1}, %{
        schema_version: "1.0"
      })

      assert_receive {:telemetry_event, [:kanban, :review, :structured_used], %{count: 1},
                      %{schema_version: "1.0"}}

      :telemetry.detach(handler_id)
    end
  end
end
