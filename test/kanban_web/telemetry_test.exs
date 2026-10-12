defmodule KanbanWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias Kanban.Telemetry.Catalog
  alias KanbanWeb.Telemetry.CatalogMetrics
  alias KanbanWeb.Telemetry.MetricsStorage
  alias Telemetry.Metrics.Counter
  alias Telemetry.Metrics.Sum
  alias Telemetry.Metrics.Summary

  # Every metric KanbanWeb.Telemetry defined before its application metrics
  # were generated from the catalog (W2344), with its type and tags. The
  # stored metrics_events history and the admin activity page read these
  # names, so none may be renamed, retyped or retagged.
  @existing_metrics [
    {"phoenix.endpoint.start.system_time", Summary, []},
    {"phoenix.endpoint.stop.duration", Summary, []},
    {"phoenix.router_dispatch.start.system_time", Summary, [:route]},
    {"phoenix.router_dispatch.exception.duration", Summary, [:route]},
    {"phoenix.router_dispatch.stop.duration", Summary, [:route]},
    {"phoenix.socket_connected.duration", Summary, []},
    {"phoenix.socket_drain.count", Sum, []},
    {"phoenix.channel_joined.duration", Summary, []},
    {"phoenix.channel_handled_in.duration", Summary, [:event]},
    {"kanban.user.registration.count", Sum, []},
    {"kanban.user.login.count", Counter, []},
    {"kanban.board.creation.count", Sum, []},
    {"kanban.api.task_created.count", Sum, []},
    {"kanban.api.task_completed.count", Sum, []},
    {"kanban.api.task_claimed.count", Counter, []},
    {"kanban.api.task_unclaimed.count", Counter, []},
    {"kanban.api.task_marked_done.count", Counter, []},
    {"kanban.api.task_returned_to_doing.count", Counter, []},
    {"kanban.api.next_task_fetched.count", Counter, []},
    {"kanban.api.after_goal_delivered.count", Counter, []},
    {"kanban.api.request.count", Counter, [:endpoint, :method]},
    {"kanban.api.request.duration", Summary, [:endpoint, :method]},
    {"kanban.api.error.count", Counter, [:endpoint, :status]},
    {"kanban.review.fallback_used.count", Counter, []},
    {"kanban.review.structured_used.count", Counter, []},
    {"kanban.review_diff_panel.opened.count", Counter, []},
    {"kanban.review_diff_panel.closed.count", Counter, []},
    {"kanban.repo.query.total_time", Summary, []},
    {"kanban.repo.query.decode_time", Summary, []},
    {"kanban.repo.query.query_time", Summary, []},
    {"kanban.repo.query.queue_time", Summary, []},
    {"kanban.repo.query.idle_time", Summary, []},
    {"vm.memory.total", Summary, []},
    {"vm.total_run_queue_lengths.total", Summary, []},
    {"vm.total_run_queue_lengths.cpu", Summary, []},
    {"vm.total_run_queue_lengths.io", Summary, []}
  ]

  # The stored rows Kanban.Metrics.UserActivity counts as admin activity.
  @stored_task_metrics [
    "kanban.api.task_claimed.count",
    "kanban.api.task_completed.count",
    "kanban.api.task_created.count",
    "kanban.api.task_marked_done.count",
    "kanban.api.task_returned_to_doing.count",
    "kanban.api.task_unclaimed.count"
  ]

  defp metrics, do: KanbanWeb.Telemetry.metrics()

  defp label(metric), do: Enum.map_join(metric.name, ".", &to_string/1)

  defp find_metric(name) do
    Enum.find(metrics(), &(label(&1) == name)) || flunk("no metric named #{name}")
  end

  defp persist_option(metric), do: Keyword.get(metric.reporter_options, :persist)

  describe "catalog metrics" do
    test "every catalog event has a metric" do
      event_names = MapSet.new(metrics(), & &1.event_name)

      for entry <- Catalog.events() do
        expected = if entry.kind == :span, do: entry.name ++ [:stop], else: entry.name

        assert MapSet.member?(event_names, expected),
               "catalog event #{inspect(entry.name)} has no metric"
      end
    end

    test "span events get duration summaries" do
      spans = Enum.filter(Catalog.events(), &(&1.kind == :span))

      assert spans != []

      for %{name: prefix} <- spans do
        metric = find_metric(Enum.map_join(prefix ++ [:stop, :duration], ".", &to_string/1))

        assert %Summary{unit: :millisecond, event_name: event_name} = metric
        assert event_name == prefix ++ [:stop]
      end
    end

    test "an entry's metrics follow its metrics, tags and persist fields" do
      entry = %{
        name: [:kanban, :widget, :sized],
        kind: :event,
        measurements: [:count, :duration],
        metadata: [:outcome, :user_id],
        description: "A widget was sized.",
        metrics: [sum: :count, summary: :duration],
        persist: true,
        tags: [:outcome]
      }

      assert [%Sum{} = sum, %Summary{} = summary] = CatalogMetrics.metrics([entry])
      assert sum.name == [:kanban, :widget, :sized, :count]
      assert sum.tags == [:outcome]
      assert sum.description == "A widget was sized."
      assert persist_option(sum) == true
      assert summary.name == [:kanban, :widget, :sized, :duration]
      assert summary.unit == :millisecond
      assert persist_option(summary) == false
    end

    test "an entry without tags or persistence gets an untagged, unstored counter" do
      entry = %{
        name: [:kanban, :widget, :polished],
        kind: :event,
        measurements: [:count],
        metadata: [:user_id],
        description: "A widget was polished.",
        metrics: [counter: :count],
        persist: false
      }

      assert [%Counter{tags: [], reporter_options: [persist: false]}] =
               CatalogMetrics.metrics([entry])
    end

    test "metric names are unique" do
      names = Enum.map(metrics(), &label/1)

      assert names -- Enum.uniq(names) == []
    end
  end

  describe "existing metrics" do
    test "existing metric names unchanged" do
      for {name, type, tags} <- @existing_metrics do
        metric = find_metric(name)

        assert metric.__struct__ == type, "#{name} changed type"
        assert metric.tags == tags, "#{name} changed tags"
      end

      assert find_metric("kanban.api.request.duration").unit == :millisecond
    end

    test "the stored kanban.api.task_ metrics are the ones admin activity counts" do
      stored =
        for metric <- metrics(),
            MetricsStorage.__persist__?(metric),
            name = label(metric),
            String.starts_with?(name, "kanban.api.task_"),
            do: name

      assert Enum.sort(stored) == @stored_task_metrics
    end
  end

  describe "framework metrics" do
    test "LiveView mount and handle_event durations are tagged by view only" do
      for name <- [
            "phoenix.live_view.mount.stop.duration",
            "phoenix.live_view.handle_event.stop.duration"
          ] do
        metric = find_metric(name)

        assert %Summary{tags: [:view], unit: :millisecond} = metric
        assert persist_option(metric) == false

        assert metric.tag_values.(%{socket: %Phoenix.LiveView.Socket{view: KanbanWeb.BoardLive}}) ==
                 %{view: "KanbanWeb.BoardLive"}
      end
    end

    test "live_view_tags/1 never raises on metadata without a socket" do
      assert KanbanWeb.Telemetry.live_view_tags(%{}) == %{}
      assert KanbanWeb.Telemetry.live_view_tags(%{socket: %{}}) == %{}
    end

    test "oban exception metric" do
      for name <- ["oban.job.exception.duration", "oban.job.stop.duration"] do
        metric = find_metric(name)

        assert %Summary{tags: [:worker, :queue], unit: :millisecond} = metric
        assert persist_option(metric) == false
      end
    end

    test "Swoosh delivery metrics are tagged by mailer only" do
      for name <- ["swoosh.deliver.stop.duration", "swoosh.deliver.exception.duration"] do
        metric = find_metric(name)

        assert %Summary{tags: [:mailer], unit: :millisecond} = metric
        assert persist_option(metric) == false
      end
    end

    test "no metric is tagged by an id" do
      for metric <- metrics(), tag <- metric.tags do
        refute tag |> Atom.to_string() |> String.ends_with?("_id"),
               "#{label(metric)} is tagged by #{inspect(tag)}"
      end
    end
  end

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
