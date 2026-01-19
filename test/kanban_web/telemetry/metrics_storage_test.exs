defmodule KanbanWeb.Telemetry.MetricsStorageTest do
  use Kanban.DataCase, async: true

  alias Kanban.Repo
  alias KanbanWeb.Telemetry.MetricsStorage

  describe "format_label/1" do
    test "formats list of atoms as dot-separated string" do
      assert MetricsStorage.__format_label__([:phoenix, :router, :dispatch]) ==
               "phoenix.router.dispatch"
    end

    test "formats list with mixed types" do
      assert MetricsStorage.__format_label__([:vm, :memory, :total]) == "vm.memory.total"
    end

    test "formats single value as string" do
      assert MetricsStorage.__format_label__("single.metric") == "single.metric"
    end

    test "formats atom as string" do
      assert MetricsStorage.__format_label__(:atom_metric) == "atom_metric"
    end
  end

  describe "extract_measurement/2" do
    test "extracts measurement using function" do
      measurements = %{duration: 100, count: 5}
      fun = fn m -> m.duration * 2 end

      assert MetricsStorage.__extract_measurement__(measurements, fun) == 200
    end

    test "extracts measurement using atom key" do
      measurements = %{duration: 100, count: 5}

      assert MetricsStorage.__extract_measurement__(measurements, :duration) == 100
    end

    test "returns nil when function raises error" do
      measurements = %{}
      fun = fn m -> m.missing_key end

      assert MetricsStorage.__extract_measurement__(measurements, fun) == nil
    end

    test "returns nil when atom key not found" do
      measurements = %{duration: 100}

      assert MetricsStorage.__extract_measurement__(measurements, :missing) == nil
    end

    test "returns nil for invalid measurement type" do
      measurements = %{duration: 100}

      assert MetricsStorage.__extract_measurement__(measurements, "string") == nil
    end
  end

  describe "sanitize_value/1" do
    test "keeps valid UTF-8 binary strings" do
      assert MetricsStorage.__sanitize_value__("hello world") == "hello world"
    end

    test "base64 encodes invalid UTF-8 binaries" do
      invalid_binary = <<255, 254, 253>>
      result = MetricsStorage.__sanitize_value__(invalid_binary)

      assert result == Base.encode64(invalid_binary)
      assert result == "//79"
    end

    test "keeps numbers unchanged" do
      assert MetricsStorage.__sanitize_value__(42) == 42
      assert MetricsStorage.__sanitize_value__(3.14) == 3.14
    end

    test "keeps booleans unchanged" do
      assert MetricsStorage.__sanitize_value__(true) == true
      assert MetricsStorage.__sanitize_value__(false) == false
    end

    test "converts atoms to strings" do
      assert MetricsStorage.__sanitize_value__(:atom_value) == "atom_value"
    end

    test "converts DateTime to ISO8601 string" do
      dt = ~U[2024-01-15 12:00:00Z]
      result = MetricsStorage.__sanitize_value__(dt)

      assert result == "2024-01-15T12:00:00Z"
    end

    test "converts NaiveDateTime to ISO8601 string" do
      ndt = ~N[2024-01-15 12:00:00]
      result = MetricsStorage.__sanitize_value__(ndt)

      assert result == "2024-01-15T12:00:00"
    end

    test "recursively sanitizes lists" do
      list = [1, "string", :atom, true]
      result = MetricsStorage.__sanitize_value__(list)

      assert result == [1, "string", "atom", true]
    end

    test "recursively sanitizes regular maps" do
      map = %{key1: "value1", key2: 42}
      result = MetricsStorage.__sanitize_value__(map)

      assert result == %{"key1" => "value1", "key2" => 42}
    end

    test "converts structs to string using inspect" do
      struct = %URI{scheme: "https", host: "example.com"}
      result = MetricsStorage.__sanitize_value__(struct)

      assert is_binary(result)
      assert String.contains?(result, "URI")
    end

    test "returns nil for unsupported types" do
      assert MetricsStorage.__sanitize_value__({:tuple, :value}) == nil
    end
  end

  describe "sanitize_metadata/1" do
    test "sanitizes map metadata with string keys" do
      metadata = %{key1: "value", key2: 42, key3: :atom}
      result = MetricsStorage.__sanitize_metadata__(metadata)

      assert result == %{"key1" => "value", "key2" => 42, "key3" => "atom"}
    end

    test "handles nested maps in metadata" do
      metadata = %{outer: %{inner: "value"}}
      result = MetricsStorage.__sanitize_metadata__(metadata)

      assert result == %{"outer" => %{"inner" => "value"}}
    end

    test "returns empty map for non-map metadata" do
      assert MetricsStorage.__sanitize_metadata__("string") == %{}
      assert MetricsStorage.__sanitize_metadata__(nil) == %{}
      assert MetricsStorage.__sanitize_metadata__(123) == %{}
    end

    test "handles metadata with DateTime values" do
      dt = ~U[2024-01-15 12:00:00Z]
      metadata = %{timestamp: dt}
      result = MetricsStorage.__sanitize_metadata__(metadata)

      assert result == %{"timestamp" => "2024-01-15T12:00:00Z"}
    end
  end

  describe "vm_metric?/1" do
    test "returns true for VM memory metrics" do
      assert MetricsStorage.__vm_metric__?([:vm, :memory, :total]) == true
    end

    test "returns true for VM run queue metrics" do
      assert MetricsStorage.__vm_metric__?([:vm, :total_run_queue_lengths, :total]) == true
    end

    test "returns true for any metric starting with :vm" do
      assert MetricsStorage.__vm_metric__?([:vm, :anything]) == true
    end

    test "returns false for non-VM metrics" do
      assert MetricsStorage.__vm_metric__?([:phoenix, :router, :dispatch]) == false
      assert MetricsStorage.__vm_metric__?([:kanban, :repo, :query]) == false
    end

    test "returns false for non-list metric names" do
      assert MetricsStorage.__vm_metric__?("vm.metric") == false
      assert MetricsStorage.__vm_metric__?(:vm) == false
    end
  end

  describe "metrics_table_query?/1" do
    test "returns true for metadata with metrics_events source" do
      metadata = %{source: "metrics_events"}

      assert MetricsStorage.__metrics_table_query__?(metadata) == true
    end

    test "returns true for query string containing metrics_events" do
      metadata = %{query: "SELECT * FROM metrics_events WHERE id = 1"}

      assert MetricsStorage.__metrics_table_query__?(metadata) == true
    end

    test "returns false for metadata without metrics_events" do
      metadata = %{source: "tasks", query: "SELECT * FROM tasks"}

      assert MetricsStorage.__metrics_table_query__?(metadata) == false
    end

    test "returns false for empty metadata" do
      assert MetricsStorage.__metrics_table_query__?(%{}) == false
    end

    test "returns false for metadata without source or query" do
      metadata = %{other_field: "value"}

      assert MetricsStorage.__metrics_table_query__?(metadata) == false
    end
  end

  describe "metrics_history/1" do
    setup do
      Repo.delete_all("metrics_events")
      :ok
    end

    test "retrieves metrics history for a specific metric with DateTime" do
      metric_name = "test.metric"
      now = DateTime.utc_now()

      Repo.insert_all("metrics_events", [
        %{
          metric_name: metric_name,
          measurement: 100.0,
          metadata: %{},
          recorded_at: now,
          inserted_at: now
        }
      ])

      metric = %{name: [:test, :metric]}
      result = MetricsStorage.metrics_history(metric)

      assert length(result) == 1
      assert [entry] = result
      assert entry.label == metric_name
      assert entry.measurement == 100.0
      assert is_integer(entry.time)
    end

    test "retrieves metrics history with NaiveDateTime conversion" do
      metric_name = "test.naive.metric"
      now = NaiveDateTime.utc_now()

      Repo.insert_all("metrics_events", [
        %{
          metric_name: metric_name,
          measurement: 50.0,
          metadata: %{},
          recorded_at: now,
          inserted_at: now
        }
      ])

      metric = %{name: [:test, :naive, :metric]}
      result = MetricsStorage.metrics_history(metric)

      assert length(result) == 1
      assert [entry] = result
      assert entry.label == metric_name
      assert entry.measurement == 50.0
      assert is_integer(entry.time)
    end

    test "retrieves multiple metrics in chronological order" do
      metric_name = "test.ordered.metric"
      now = DateTime.utc_now()

      Repo.insert_all("metrics_events", [
        %{
          metric_name: metric_name,
          measurement: 1.0,
          metadata: %{},
          recorded_at: DateTime.add(now, -60, :second),
          inserted_at: now
        },
        %{
          metric_name: metric_name,
          measurement: 2.0,
          metadata: %{},
          recorded_at: DateTime.add(now, -30, :second),
          inserted_at: now
        },
        %{
          metric_name: metric_name,
          measurement: 3.0,
          metadata: %{},
          recorded_at: now,
          inserted_at: now
        }
      ])

      metric = %{name: [:test, :ordered, :metric]}
      result = MetricsStorage.metrics_history(metric)

      assert length(result) == 3
      assert Enum.map(result, & &1.measurement) == [1.0, 2.0, 3.0]
    end

    test "returns empty list when no metrics found" do
      metric = %{name: [:nonexistent, :metric]}
      result = MetricsStorage.metrics_history(metric)

      assert result == []
    end
  end

  describe "handle_event/4" do
    test "skips events for metrics_events table queries" do
      measurements = %{duration: 100}
      metadata = %{source: "metrics_events"}
      config = %{metric: %{name: [:test], measurement: :duration}}

      result = MetricsStorage.handle_event([:test], measurements, metadata, config)

      assert result == :ok
    end

    test "skips VM metrics to prevent database bloat" do
      measurements = %{total: 1_000_000}
      metadata = %{}
      metric = %{name: [:vm, :memory, :total], measurement: :total}
      config = %{metric: metric}

      result = MetricsStorage.handle_event([:vm, :memory, :total], measurements, metadata, config)

      assert result == :ok
    end

    test "sends telemetry event message when not metrics_events query" do
      measurements = %{duration: 100}
      metadata = %{source: "tasks"}
      metric = %{name: [:test, :metric], measurement: :duration}
      config = %{metric: metric}

      Process.register(self(), MetricsStorage)

      MetricsStorage.handle_event([:test], measurements, metadata, config)

      assert_received {:telemetry_event, [:test, :metric], 100, %{source: "tasks"}}

      Process.unregister(MetricsStorage)
    end

    test "skips event when measurement extraction returns nil" do
      measurements = %{other: 100}
      metadata = %{}
      metric = %{name: [:test], measurement: :missing}
      config = %{metric: metric}

      result = MetricsStorage.handle_event([:test], measurements, metadata, config)

      assert result in [:ok, nil]
    end
  end

  describe "handle_info/2" do
    setup do
      Repo.delete_all("metrics_events")
      :ok
    end

    test "stores telemetry event in database" do
      metric_name = [:test, :metric]
      measurement = 42.5
      metadata = %{key: "value"}

      {:noreply, state} =
        MetricsStorage.handle_info(
          {:telemetry_event, metric_name, measurement, metadata},
          %{metrics: []}
        )

      assert state == %{metrics: []}

      result =
        from(m in "metrics_events",
          select: %{
            metric_name: m.metric_name,
            measurement: m.measurement,
            metadata: m.metadata
          }
        )
        |> Repo.one()

      assert result.metric_name == "test.metric"
      assert result.measurement == 42.5
      assert result.metadata == %{"key" => "value"}
    end

    test "sanitizes metadata when storing event" do
      metric_name = [:test, :sanitize]
      measurement = 10.0

      metadata = %{
        string: "value",
        atom: :test,
        number: 42,
        datetime: ~U[2024-01-15 12:00:00Z]
      }

      MetricsStorage.handle_info(
        {:telemetry_event, metric_name, measurement, metadata},
        %{metrics: []}
      )

      result =
        from(m in "metrics_events",
          select: %{
            metric_name: m.metric_name,
            metadata: m.metadata
          }
        )
        |> Repo.one()

      assert result.metadata == %{
               "string" => "value",
               "atom" => "test",
               "number" => 42,
               "datetime" => "2024-01-15T12:00:00Z"
             }
    end
  end
end
