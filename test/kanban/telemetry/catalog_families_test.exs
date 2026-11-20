defmodule Kanban.Telemetry.CatalogFamiliesTest do
  # Kanban.Telemetry.Catalog builds @events from each family's events/0 at
  # compile time, so cover never sees a runtime call. These tests call every
  # family at runtime and pin how the families compose into the catalog.
  # Production code must still never call a family module directly.
  use ExUnit.Case, async: true

  alias Kanban.Telemetry.Catalog

  alias Kanban.Telemetry.Catalog.ApiEvents
  alias Kanban.Telemetry.Catalog.AttachmentEvents
  alias Kanban.Telemetry.Catalog.AuditStreamEvents
  alias Kanban.Telemetry.Catalog.BoardEvents
  alias Kanban.Telemetry.Catalog.DecisionEvents
  alias Kanban.Telemetry.Catalog.DeviceEvents
  alias Kanban.Telemetry.Catalog.Families
  alias Kanban.Telemetry.Catalog.GoalEvents
  alias Kanban.Telemetry.Catalog.MessageEvents
  alias Kanban.Telemetry.Catalog.NotificationEvents
  alias Kanban.Telemetry.Catalog.OrganizationEvents
  alias Kanban.Telemetry.Catalog.PlanEvents
  alias Kanban.Telemetry.Catalog.PushEvents
  alias Kanban.Telemetry.Catalog.ReviewEvents
  alias Kanban.Telemetry.Catalog.ReviewPanelEvents
  alias Kanban.Telemetry.Catalog.TargetEvents
  alias Kanban.Telemetry.Catalog.TaskEvents
  alias Kanban.Telemetry.Catalog.TaskLifecycleEvents
  alias Kanban.Telemetry.Catalog.UserEvents

  # In the order lib/kanban/telemetry/catalog.ex concatenates them after
  # @core_events.
  @families [
    ApiEvents,
    TaskLifecycleEvents,
    ReviewPanelEvents,
    BoardEvents,
    TaskEvents,
    UserEvents,
    Families,
    NotificationEvents,
    TargetEvents,
    MessageEvents,
    GoalEvents,
    OrganizationEvents,
    PlanEvents,
    AttachmentEvents,
    AuditStreamEvents,
    DeviceEvents,
    ReviewEvents,
    DecisionEvents,
    PushEvents
  ]

  @family_dir Path.expand("../../../lib/kanban/telemetry/catalog", __DIR__)

  @entry_fields [
    :name,
    :kind,
    :domain,
    :measurements,
    :metadata,
    :description,
    :legacy,
    :metrics,
    :persist
  ]
  @optional_entry_fields [:tags]

  test "covers every family module on disk" do
    # Compared as names, so a file with no matching module creates no atom.
    on_disk =
      @family_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.map(&"#{inspect(Catalog)}.#{&1 |> Path.basename(".ex") |> Macro.camelize()}")
      |> Enum.sort()

    listed = @families |> Enum.map(&inspect/1) |> Enum.sort()

    assert on_disk != [], "no family files found under #{Path.relative_to_cwd(@family_dir)}"

    assert listed == on_disk,
           "the test's @families must list exactly the modules in " <>
             "lib/kanban/telemetry/catalog/; missing: " <>
             "#{inspect(on_disk -- listed)}, extra: #{inspect(listed -- on_disk)}"
  end

  test "each family returns well-formed entries" do
    for family <- @families do
      entries = family.events()

      assert is_list(entries) and entries != [], "#{inspect(family)}.events/0 is empty"

      for entry <- entries do
        assert is_map(entry)

        assert entry |> Map.keys() |> Kernel.--(@optional_entry_fields) |> Enum.sort() ==
                 Enum.sort(@entry_fields),
               "#{inspect(family)} entry #{inspect(entry[:name])} must declare " <>
                 "exactly #{inspect(@entry_fields)}"

        assert is_list(entry.name) and Enum.all?(entry.name, &is_atom/1)
      end
    end
  end

  test "every family entry is a member of Catalog.events/0" do
    catalog = MapSet.new(Catalog.events())

    for family <- @families, entry <- family.events() do
      assert MapSet.member?(catalog, entry),
             "#{inspect(entry.name)} from #{inspect(family)} is not in Catalog.events/0"
    end
  end

  test "every family is wired into the catalog in order" do
    catalog = Catalog.events()

    family_end =
      Enum.reduce(@families, nil, fn family, previous_end ->
        entries = family.events()
        start = Enum.find_index(catalog, &(&1 == hd(entries)))

        assert start, "#{inspect(family)} is not wired into Catalog.events/0"

        assert Enum.slice(catalog, start, length(entries)) == entries,
               "#{inspect(family)}'s entries are not contiguous in Catalog.events/0"

        assert previous_end == nil or start == previous_end,
               "#{inspect(family)} is not where catalog.ex declares it in Catalog.events/0"

        start + length(entries)
      end)

    assert family_end == length(catalog),
           "the families' entries must end Catalog.events/0"
  end

  test "no event name is claimed by two families" do
    claimed =
      for family <- @families, entry <- family.events(), do: {entry.name, family}

    duplicates =
      claimed
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_name, families} -> length(families) > 1 end)

    assert duplicates == [], "event names declared more than once: #{inspect(duplicates)}"
  end
end
