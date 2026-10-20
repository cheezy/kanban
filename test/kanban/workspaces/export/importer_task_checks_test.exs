defmodule Kanban.Workspaces.Export.Importer.TaskChecksTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Importer.TaskChecks

  # Source columns 10 and 11 are on board 1, column 20 on board 2. Column 99
  # is not imported.
  @boards %{10 => 1, 11 => 1, 20 => 2}

  defp task(id, identifier, column_id, extra \\ %{}),
    do: Map.merge(%{"id" => id, "identifier" => identifier, "column_id" => column_id}, extra)

  defp goal_with_children do
    [
      task(1, "G1", 10),
      task(2, "W1", 10, %{"parent_id" => 1}),
      task(3, "W2", 11, %{"parent_id" => 1}),
      task(4, "W1", 20)
    ]
  end

  describe "check/2" do
    test "accepts a well-formed hierarchy, the same identifier on two boards included" do
      assert TaskChecks.check(goal_with_children(), @boards) == :ok
    end

    test "accepts a link to a task that is not imported, leaving it to the importer" do
      rows = [task(1, "W1", 10, %{"parent_id" => 2}), task(2, "G1", 99)]

      assert TaskChecks.check(rows, @boards) == :ok
    end

    test "reports the first failing check" do
      rows = [task(1, nil, 10), task(2, "W1", 10, %{"parent_id" => 2})]

      assert TaskChecks.check(rows, @boards) == {:error, "row 1", :invalid_identifier}
    end
  end

  describe "valid_identifier?/1" do
    test "accepts a letter prefix and a number" do
      for identifier <- ["W1", "G12", "D2147483647", "ABCD1"] do
        assert TaskChecks.valid_identifier?(identifier), identifier
      end
    end

    test "refuses nil, non-strings, blanks and control or bidi characters" do
      for identifier <- [
            nil,
            12,
            "",
            "W",
            "1",
            "w1",
            "W1 ",
            "W1\n",
            "W\u202E1",
            "\u200FW1",
            "W1\u0000",
            "Ｗ1",
            "W١"
          ] do
        refute TaskChecks.valid_identifier?(identifier), inspect(identifier)
      end
    end
  end

  describe "check_identifiers/1" do
    test "names a refused identifier by its row, never by its bytes" do
      rows = [task(1, "W1", 10), task(2, "W\u202E2", 10)]

      assert TaskChecks.check_identifiers(rows) == {:error, "row 2", :invalid_identifier}
    end

    test "checks rows whose column is not imported too" do
      assert TaskChecks.check([task(1, nil, 99)], @boards) ==
               {:error, "row 1", :invalid_identifier}
    end
  end

  describe "check_unique_identifiers/2" do
    test "refuses two tasks on one board with the same identifier, across its columns" do
      rows = [task(1, "W1", 10), task(2, "W1", 11)]

      assert TaskChecks.check_unique_identifiers(rows, @boards) ==
               {:error, "W1", :duplicate_identifier}
    end

    test "allows the same identifier on different boards" do
      assert TaskChecks.check_unique_identifiers([task(1, "W1", 10), task(2, "W1", 20)], @boards) ==
               :ok
    end
  end

  describe "check_links/2" do
    test "refuses a task that is its own parent" do
      rows = [task(1, "W1", 10, %{"parent_id" => 1})]

      assert TaskChecks.check_links(rows, @boards) == {:error, "W1", :parent_is_itself}
    end

    test "refuses a parent on another board" do
      rows = [task(1, "G1", 10), task(2, "W1", 20, %{"parent_id" => 1})]

      assert TaskChecks.check_links(rows, @boards) == {:error, "W1", :parent_on_another_board}
    end

    test "refuses an archived duplicate of a task on another board" do
      rows = [
        task(1, "W1", 10),
        task(2, "W2", 20, %{"archive_reason" => "duplicate", "duplicate_of_id" => 1})
      ]

      assert TaskChecks.check_links(rows, @boards) ==
               {:error, "W2", :duplicate_on_another_board}
    end

    test "ignores duplicate_of_id unless the task is archived as a duplicate" do
      rows = [task(1, "W1", 10), task(2, "W2", 20, %{"duplicate_of_id" => 1})]

      assert TaskChecks.check_links(rows, @boards) == :ok
    end
  end

  describe "check_parent_cycles/1" do
    test "refuses a parent cycle" do
      rows = [
        task(1, "W1", 10, %{"parent_id" => 3}),
        task(2, "W2", 10, %{"parent_id" => 1}),
        task(3, "W3", 10, %{"parent_id" => 2})
      ]

      assert {:error, ref, :parent_cycle} = TaskChecks.check_parent_cycles(rows)
      assert ref in ["W1", "W2", "W3"]
    end

    test "refuses a cycle reached from a task outside it" do
      rows = [
        task(1, "W1", 10, %{"parent_id" => 2}),
        task(2, "W2", 10, %{"parent_id" => 3}),
        task(3, "W3", 10, %{"parent_id" => 2})
      ]

      assert {:error, ref, :parent_cycle} = TaskChecks.check_parent_cycles(rows)
      assert ref in ["W2", "W3"]
    end

    test "accepts a long chain and stops at a parent that is not imported" do
      rows =
        for id <- 1..5_000,
            do: task(id, "W#{id}", 10, %{"parent_id" => id + 1})

      assert TaskChecks.check_parent_cycles(rows) == :ok
    end
  end
end
