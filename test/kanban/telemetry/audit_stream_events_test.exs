defmodule Kanban.Telemetry.AuditStreamEventsTest do
  # DataCase, because AuditLog.event/2 also inserts an audit_events row.
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.AuditLog
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Telemetry.Catalog
  alias Kanban.Telemetry.Catalog.AuditStreamEvents
  alias KanbanWeb.Telemetry.MetricsStorage

  @delivered [:kanban, :audit_stream, :batch_delivered]
  @failed [:kanban, :audit_stream, :batch_failed]
  @lag [:kanban, :audit_stream, :lag_measured]
  @gap [:kanban, :audit_stream, :gap_recorded]

  # Each event with the measurements and metadata its entry declares.
  @emits [
    {@delivered, %{count: 1, events: 50, bytes: 4096, duration_ms: 120}, %{kind: :splunk_hec}},
    {@failed, %{count: 1, duration_ms: 3000}, %{kind: :https, outcome: :retry}},
    {@lag, %{lag_seconds: 42, events_waiting: 7, events_above_horizon: 2}, %{kind: :datadog}},
    {@gap, %{count: 1, events: 300}, %{kind: :https, reason: :retention}}
  ]

  # Keys that would identify an Organization or a destination.
  @identifying_keys [:organization_id, :url, :host, :url_host, :destination_name, :name, :email]

  describe "catalog entries" do
    test "declares the four audit_stream events, in order, through the catalog" do
      assert Enum.map(AuditStreamEvents.events(), & &1.name) == [@delivered, @failed, @lag, @gap]

      for entry <- AuditStreamEvents.events() do
        assert {:ok, ^entry} = Catalog.fetch(entry.name)
        assert entry.domain == :audit_stream
        refute entry.legacy
      end
    end

    test "no entry declares an identifying key, or a tag that is not a fixed label" do
      for entry <- AuditStreamEvents.events() do
        assert entry.metadata -- @identifying_keys == entry.metadata
        assert Map.get(entry, :tags, []) -- [:kind, :outcome, :reason] == []
      end
    end

    test "declares the metrics and tags the design names" do
      by_name = Map.new(AuditStreamEvents.events(), &{&1.name, &1})

      assert by_name[@delivered].metrics == [counter: :count, sum: :events, summary: :duration_ms]
      assert by_name[@delivered].tags == [:kind]
      assert by_name[@failed].tags == [:kind, :outcome]
      assert by_name[@gap].metadata == [:kind, :reason]
      assert Enum.map(AuditStreamEvents.events(), & &1.persist) == [false, false, true, false]
    end
  end

  describe "emitting" do
    test "each of the four events is delivered to attach_telemetry" do
      attach_telemetry(Enum.map(@emits, &elem(&1, 0)))

      for {event, measurements, metadata} <- @emits do
        assert :ok = Kanban.Telemetry.emit(event, measurements, metadata)
        assert_receive {:telemetry_event, ^event, ^measurements, ^metadata}
      end
    end

    test "an undeclared metadata key raises in strict mode" do
      for {event, measurements, metadata} <- @emits do
        assert_raise ArgumentError, fn ->
          Kanban.Telemetry.emit(event, measurements, Map.put(metadata, :organization_id, 1))
        end
      end
    end
  end

  describe "lag_measured" do
    test "lag_measured is persisted with lag_seconds as its first metric" do
      [first | rest] =
        Enum.filter(KanbanWeb.Telemetry.metrics(), &(Enum.take(&1.name, 3) == @lag))

      assert first.name == @lag ++ [:lag_seconds]
      assert %Telemetry.Metrics.Summary{tags: [:kind]} = first
      assert MetricsStorage.__persist__?(first)
      refute Enum.any?(rest, &MetricsStorage.__persist__?/1)
    end

    test "docs/telemetry.md lists the lag summary among the stored metrics" do
      docs = File.read!("docs/telemetry.md")
      [_before, after_heading] = String.split(docs, "\nStored today:\n", parts: 2)
      [stored_list | _rest] = String.split(after_heading, "\n\nThe API request", parts: 2)

      assert stored_list =~ "`audit_stream.lag_measured.lag_seconds`"
    end

    test "no other audit_stream metric is persisted" do
      others =
        for metric <- KanbanWeb.Telemetry.metrics(),
            Enum.take(metric.name, 2) == [:kanban, :audit_stream],
            Enum.take(metric.name, 3) != @lag,
            do: metric

      assert length(others) == 5
      refute Enum.any?(others, &MetricsStorage.__persist__?/1)
    end
  end

  describe "audit actions" do
    test "telemetry omits them: destination_name and url_host are stored but never emitted" do
      user = user_fixture()
      organization = organization_fixture()

      attach_telemetry([
        [:kanban, :audit, :audit_stream_destination_created],
        [:kanban, :telemetry, :metadata_dropped]
      ])

      assert :ok =
               AuditLog.event(:audit_stream_destination_created,
                 user_id: user.id,
                 organization_id: organization.id,
                 destination_id: 9,
                 kind: :https,
                 start_from: :now,
                 include_personal_data: false,
                 destination_name: "Security SIEM",
                 url_host: "siem.internal.test"
               )

      assert_receive {:telemetry_event, [:kanban, :audit, :audit_stream_destination_created],
                      %{count: 1}, metadata}

      assert metadata == %{
               user_id: user.id,
               organization_id: organization.id,
               destination_id: 9,
               kind: :https,
               start_from: :now,
               include_personal_data: false
             }

      # Omitted before the catalog sees them, so they are never even dropped.
      refute_received {:telemetry_event, [:kanban, :telemetry, :metadata_dropped], _, _}

      assert [row] = Repo.all(AuditEvent)
      assert row.action == "audit_stream_destination_created"
      assert row.metadata["destination_name"] == "Security SIEM"
      assert row.metadata["url_host"] == "siem.internal.test"
    end

    test "audit_stream_cursors_reseeded carries only destinations besides the ids" do
      assert {:ok, entry} = Catalog.fetch([:kanban, :audit, :audit_stream_cursors_reseeded])
      assert entry.metadata == [:user_id, :organization_id, :destinations]

      attach_telemetry([:kanban, :audit, :audit_stream_cursors_reseeded])
      organization = organization_fixture()

      assert :ok =
               AuditLog.event(:audit_stream_cursors_reseeded,
                 organization_id: organization.id,
                 destinations: 2
               )

      assert_receive {:telemetry_event, [:kanban, :audit, :audit_stream_cursors_reseeded],
                      %{count: 1}, %{organization_id: _, destinations: 2} = metadata}

      assert map_size(metadata) == 2
    end

    test "no audit_stream action declares a destination name or host" do
      entries =
        for %{name: [:kanban, :audit, action]} = entry <- Catalog.events(),
            action |> Atom.to_string() |> String.starts_with?("audit_stream_"),
            do: entry

      assert length(entries) == 13

      for entry <- entries do
        assert [:user_id, :organization_id | _] = entry.metadata
        refute :destination_name in entry.metadata
        refute :url_host in entry.metadata
      end
    end
  end
end
