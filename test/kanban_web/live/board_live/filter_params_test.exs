defmodule KanbanWeb.BoardLive.FilterParamsTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.BoardFilters
  alias KanbanWeb.BoardLive.FilterParams

  describe "parse/1" do
    test "parses every whitelisted value" do
      assert FilterParams.parse(%{
               "q" => "login",
               "type" => "defect",
               "priority" => "critical",
               "assignee" => "42",
               "label" => "7"
             }) == %BoardFilters{
               search: "login",
               type: :defect,
               priority: :critical,
               assignee: 42,
               label_id: 7
             }

      for type <- ~w(work defect goal) do
        assert FilterParams.parse(%{"type" => type}).type == String.to_existing_atom(type)
      end

      for priority <- ~w(low medium high critical) do
        assert FilterParams.parse(%{"priority" => priority}).priority ==
                 String.to_existing_atom(priority)
      end

      assert FilterParams.parse(%{"assignee" => "unassigned"}).assignee == :unassigned
    end

    test "an empty or absent params map is no filter" do
      assert FilterParams.parse(%{}) == %BoardFilters{}
      assert FilterParams.parse(%{"id" => "12"}) == %BoardFilters{}
      assert FilterParams.parse(nil) == %BoardFilters{}
    end

    test "ignores unknown and malformed values" do
      assert FilterParams.parse(%{
               "type" => "epic",
               "priority" => "URGENT",
               "assignee" => "abc",
               "label" => "12abc"
             }) == %BoardFilters{}

      for bad <- ["0", "-3", "1.5", " 4", "", "9e9"] do
        assert FilterParams.parse(%{"assignee" => bad}).assignee == nil
        assert FilterParams.parse(%{"label" => bad}).label_id == nil
      end
    end

    test "ignores non-binary values and unknown keys" do
      assert FilterParams.parse(%{
               "q" => ["a", "b"],
               "type" => %{"x" => "work"},
               "priority" => ["high"],
               "assignee" => %{},
               "label" => ["1"],
               "sort" => "desc"
             }) == %BoardFilters{}
    end

    test "trims search text and treats blank as no search" do
      assert FilterParams.parse(%{"q" => "  needle  "}).search == "needle"
      assert FilterParams.parse(%{"q" => "   "}).search == nil
      assert FilterParams.parse(%{"q" => ""}).search == nil
    end

    test "caps very long search text" do
      long = String.duplicate("é", 500)

      search = FilterParams.parse(%{"q" => long}).search

      assert FilterParams.max_search_length() == 100
      assert String.length(search) == 100
    end

    test "never creates atoms from input" do
      raw = "type_#{System.unique_integer([:positive])}"

      assert FilterParams.parse(%{"type" => raw, "priority" => raw}) == %BoardFilters{}
      assert_raise ArgumentError, fn -> String.to_existing_atom(raw) end
    end
  end

  describe "restrict/3" do
    test "drops an assignee that is not a board member and a foreign label" do
      filters = %BoardFilters{assignee: 99, label_id: 500, type: :work}

      assert FilterParams.restrict(filters, [1, 2], [10]) == %BoardFilters{type: :work}
    end

    test "keeps member assignees, board labels and :unassigned" do
      assert FilterParams.restrict(%BoardFilters{assignee: 2, label_id: 10}, [1, 2], [10]) ==
               %BoardFilters{assignee: 2, label_id: 10}

      assert FilterParams.restrict(%BoardFilters{assignee: :unassigned}, [], []) ==
               %BoardFilters{assignee: :unassigned}
    end
  end

  describe "encode/1" do
    test "omits unset dimensions" do
      assert FilterParams.encode(%BoardFilters{}) == []
      assert FilterParams.encode(%BoardFilters{priority: :low}) == [{"priority", "low"}]
    end

    test "writes keys in a stable order" do
      filters = %BoardFilters{
        label_id: 3,
        assignee: :unassigned,
        priority: :high,
        type: :goal,
        search: "x"
      }

      assert filters |> FilterParams.encode() |> Enum.map(&elem(&1, 0)) ==
               ~w(q type priority assignee label)
    end

    test "round-trips through parse" do
      for filters <- [
            %BoardFilters{},
            %BoardFilters{search: "Fix 100% of a_b"},
            %BoardFilters{type: :defect, priority: :critical},
            %BoardFilters{assignee: :unassigned, label_id: 8},
            %BoardFilters{search: "q", type: :work, priority: :low, assignee: 5, label_id: 1}
          ] do
        assert filters |> FilterParams.encode() |> Map.new() |> FilterParams.parse() == filters
      end
    end
  end

  describe "form_values/1" do
    test "gives every input a string value" do
      assert FilterParams.form_values(%BoardFilters{assignee: 4, type: :work}) == %{
               "q" => "",
               "type" => "work",
               "priority" => "",
               "assignee" => "4",
               "label" => ""
             }
    end
  end
end
