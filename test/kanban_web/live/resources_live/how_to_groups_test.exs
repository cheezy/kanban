defmodule KanbanWeb.ResourcesLive.HowToGroupsTest do
  @moduledoc """
  Contract test for the `KanbanWeb.ResourcesLive.HowTos.*` group modules.

  `HowToData` concatenates every group's `how_tos/0` into its catalog at
  compile time, so cover never sees a runtime call to a group. This test calls
  each group at runtime and pins how the groups compose into `HowToData`:
  every group is wired in, in catalog order, and guide ids stay unique across
  groups. It deliberately asserts no titles, counts or step text, so guide
  content can change without touching it.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.ResourcesLive.HowToData
  alias KanbanWeb.ResourcesLive.HowTos

  # Mirrors the order of `@how_tos` in lib/kanban_web/live/resources_live/how_to_data.ex.
  @groups [
    HowTos.GettingStarted,
    HowTos.Boards,
    HowTos.Account,
    HowTos.Organizations,
    HowTos.OrgAdmin,
    HowTos.AgentPlugins,
    HowTos.Developer,
    HowTos.WorkingWithTasks,
    HowTos.TaskDetails,
    HowTos.AgentsAndPlanning,
    HowTos.NotificationsAndIntegrations,
    HowTos.Metrics
  ]

  @groups_dir Path.expand("../../../../lib/kanban_web/live/resources_live/how_tos", __DIR__)

  @required_fields [
    :id,
    :title,
    :description,
    :tags,
    :content_type,
    :reading_time,
    :created_at,
    :steps
  ]

  test "covers every group module on disk" do
    # Compared as names, not atoms, so a stray file cannot create an atom.
    on_disk =
      @groups_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.map(&"#{inspect(HowTos)}.#{Macro.camelize(Path.rootname(&1))}")
      |> Enum.sort()

    assert on_disk != [], "found no group modules in #{@groups_dir}"

    missing = on_disk -- Enum.map(@groups, &inspect/1)
    assert missing == [], "group modules on disk but not in @groups: #{inspect(missing)}"

    assert length(@groups) == length(on_disk)
  end

  test "each group returns well-formed guides" do
    for group <- @groups do
      how_tos = group.how_tos()

      assert is_list(how_tos)
      assert how_tos != [], "#{inspect(group)}.how_tos/0 returned no guides"

      for how_to <- how_tos do
        for field <- @required_fields do
          assert Map.has_key?(how_to, field),
                 "#{inspect(group)} guide #{inspect(how_to[:id])} is missing #{inspect(field)}"
        end

        assert is_binary(how_to.id) and how_to.id != ""
        assert is_binary(how_to.title)
        assert is_binary(how_to.description)
        assert is_list(how_to.tags) and how_to.tags != []
        assert is_binary(how_to.content_type)
        assert is_integer(how_to.reading_time)
        assert %Date{} = how_to.created_at
        assert is_list(how_to.steps) and how_to.steps != []
      end
    end
  end

  test "every group is wired into HowToData in order" do
    for group <- @groups, how_to <- group.how_tos() do
      assert HowToData.get_how_to(how_to.id) == {:ok, how_to},
             "#{inspect(group)} guide #{inspect(how_to.id)} is not in HowToData; " <>
               "is #{inspect(group)} missing from @how_tos in how_to_data.ex?"
    end

    assert Enum.map(HowToData.all_how_tos(), & &1.id) ==
             Enum.flat_map(@groups, fn group -> Enum.map(group.how_tos(), & &1.id) end),
           "HowToData.all_how_tos/0 is not the groups concatenated in catalog order"
  end

  test "guide ids are unique across groups" do
    ids = Enum.flat_map(@groups, fn group -> Enum.map(group.how_tos(), & &1.id) end)
    duplicates = Enum.uniq(ids -- Enum.uniq(ids))

    assert duplicates == [], "guide ids used more than once: #{inspect(duplicates)}"
  end
end
