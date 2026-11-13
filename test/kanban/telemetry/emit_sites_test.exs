defmodule Kanban.Telemetry.EmitSitesTest do
  @moduledoc """
  Checks the app's telemetry call sites against `Kanban.Telemetry.Catalog`,
  by scanning the source with `Kanban.TelemetrySourceScan`.
  """
  use ExUnit.Case, async: true

  alias Kanban.Telemetry.Catalog
  alias Kanban.TelemetrySourceScan

  # Only these two build an event name from an action at runtime; each action
  # is catalogued and found below through its literal call sites.
  @dynamic_name_files [
    "lib/kanban/audit_log.ex",
    "lib/kanban_web/controllers/api/task_actions.ex"
  ]

  # TEMPORARY: the audit log streaming events and audit actions are declared
  # up front (design task A5) so later tasks can emit them in strict mode.
  # Each task that adds a call site removes its names here; the list is empty,
  # and can be deleted, once every one of them is emitted.
  @awaiting_emit_site [
    [:kanban, :audit_stream, :gap_recorded],
    [:kanban, :audit, :audit_stream_gap],
    [:kanban, :audit, :audit_stream_gap_dismissed],
    [:kanban, :audit, :audit_stream_cursors_reseeded]
  ]

  setup_all do
    %{scan: TelemetrySourceScan.scan("lib")}
  end

  test "only lib/kanban/telemetry.ex calls :telemetry.execute or :telemetry.span", %{scan: scan} do
    assert scan.raw_calls != []
    assert scan.raw_calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == ["lib/kanban/telemetry.ex"]
  end

  test "event names are built at runtime only by the API and audit emitters", %{scan: scan} do
    dynamic = for %{name: :dynamic} = site <- scan.sites, do: site.file

    assert dynamic |> Enum.uniq() |> Enum.sort() == Enum.sort(@dynamic_name_files)
  end

  test "every catalogued event has an emit site", %{scan: scan} do
    emitted = MapSet.new(scan.sites, & &1.name)

    # metadata_dropped is emitted by Kanban.Telemetry itself.
    unused =
      for %{name: name} <- Catalog.events(),
          name != [:kanban, :telemetry, :metadata_dropped],
          name not in @awaiting_emit_site,
          not MapSet.member?(emitted, name),
          do: name

    assert unused == []
  end

  test "the awaiting list names only catalogued events that have no emit site yet",
       %{scan: scan} do
    emitted = MapSet.new(scan.sites, & &1.name)

    assert length(@awaiting_emit_site) == length(Enum.uniq(@awaiting_emit_site))
    assert Enum.all?(@awaiting_emit_site, &match?({:ok, _}, Catalog.fetch(&1)))

    # A name whose call site now exists must be removed from the list.
    assert Enum.filter(@awaiting_emit_site, &MapSet.member?(emitted, &1)) == []
  end

  test "every API and audit action is found and catalogued", %{scan: scan} do
    api = for %{kind: :api, name: name} <- scan.sites, uniq: true, do: name
    audit = for %{kind: :audit, name: name} <- scan.sites, uniq: true, do: name

    assert length(api) >= 23
    assert length(audit) >= 16
    assert Enum.all?(api ++ audit, &match?({:ok, _}, Catalog.fetch(&1)))
  end

  test "every kanban.api.task_* event declares user_id for the admin activity counts" do
    # Kanban.Metrics.UserActivity counts stored kanban.api.task_* events by
    # metadata user_id.
    task_events =
      for %{name: [:kanban, :api, action]} = entry <- Catalog.events(),
          action |> Atom.to_string() |> String.starts_with?("task_"),
          do: entry

    assert length(task_events) >= 10
    assert Enum.all?(task_events, &(:user_id in &1.metadata))
  end
end
