defmodule Kanban.ColumnsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Columns
  alias Kanban.Columns.Column

  describe "list_columns/1" do
    test "returns all columns for a board ordered by position" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      columns = Columns.list_columns(board)

      assert length(columns) == 3
      assert Enum.map(columns, & &1.id) == [column1.id, column2.id, column3.id]
      assert Enum.map(columns, & &1.position) == [0, 1, 2]
    end

    test "returns empty list when board has no columns" do
      user = user_fixture()
      board = board_fixture(user)

      assert Columns.list_columns(board) == []
    end

    test "only returns columns for the specified board" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      column_fixture(board1)
      column_fixture(board2)

      assert length(Columns.list_columns(board1)) == 1
      assert length(Columns.list_columns(board2)) == 1
    end
  end

  describe "get_column!/1" do
    test "returns the column with given id" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert Columns.get_column!(column.id).id == column.id
    end

    test "raises error when column does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Columns.get_column!(999_999)
      end
    end
  end

  describe "get_column_by_name/2" do
    test "get_column_by_name/2 matches case-insensitively and only on the given board" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)

      _backlog = column_fixture(board, %{name: "Backlog"})
      ready = column_fixture(board, %{name: "  Ready "})
      _other_ready = column_fixture(other_board, %{name: "Ready"})

      assert %Column{id: id} = Columns.get_column_by_name(board.id, "ready")
      assert id == ready.id
      assert %Column{id: ^id} = Columns.get_column_by_name(board.id, " READY ")
    end

    test "returns nil when the board has no column with that name" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)
      column_fixture(other_board, %{name: "Ready"})
      column_fixture(board, %{name: "Ready soon"})

      assert Columns.get_column_by_name(board.id, "Ready") == nil
    end

    test "returns the lowest-positioned match when names repeat" do
      user = user_fixture()
      board = board_fixture(user)
      first = column_fixture(board, %{name: "Ready"})
      _second = column_fixture(board, %{name: "ready"})

      assert Columns.get_column_by_name(board.id, "Ready").id == first.id
    end

    test "matches a name padded with tabs or newlines, agreeing with named?/2" do
      user = user_fixture()
      board = board_fixture(user)
      ready = column_fixture(board, %{name: "\tReady\n"})

      assert Columns.named?(ready, "Ready")
      assert Columns.get_column_by_name(board.id, "Ready").id == ready.id
    end

    test "returns nil for a non-binary name" do
      user = user_fixture()
      board = board_fixture(user)
      column_fixture(board, %{name: "Ready"})

      assert Columns.get_column_by_name(board.id, nil) == nil
    end
  end

  describe "named?/2" do
    test "matches ignoring case and surrounding whitespace" do
      assert Columns.named?(%Column{name: " backlog "}, "Backlog")
      assert Columns.named?(%Column{name: "READY"}, "ready")
      assert Columns.named?(%{name: "Ready"}, "  Ready\t")
    end

    test "does not match a different name" do
      refute Columns.named?(%Column{name: "To Do"}, "Backlog")
      refute Columns.named?(%Column{name: "Ready soon"}, "Ready")
    end

    test "is false for a nil column, a nil column name or a non-binary name" do
      refute Columns.named?(nil, "Backlog")
      refute Columns.named?(%Column{name: nil}, "Backlog")
      refute Columns.named?(%Column{name: "Backlog"}, nil)
    end
  end

  describe "create_column/3" do
    test "creates a column with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "To Do"}, user)

      assert column.name == "To Do"
      assert column.position == 0
      assert column.wip_limit == 0
      assert column.board_id == board.id
    end

    test "creates columns with sequential positions" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, column1} = Columns.create_column(board, %{name: "First"}, user)
      {:ok, column2} = Columns.create_column(board, %{name: "Second"}, user)
      {:ok, column3} = Columns.create_column(board, %{name: "Third"}, user)

      assert column1.position == 0
      assert column2.position == 1
      assert column3.position == 2
    end

    test "creates a column with custom wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "In Progress", wip_limit: 5}, user)

      assert column.wip_limit == 5
    end

    test "defaults wip_limit to 0 when not provided" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Done"}, user)

      assert column.wip_limit == 0
    end

    test "returns error when name is missing" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, %Ecto.Changeset{}} = Columns.create_column(board, %{}, user)
    end

    test "accepts string-keyed attrs without raising on unknown keys" do
      # An unknown string key used to raise ArgumentError from
      # String.to_existing_atom/1. cast/3 silently ignores unknown
      # fields, so we should get a controlled {:ok, _} (when the
      # known string-keyed fields are valid) without a crash.
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{name: "From Strings"}} =
               Columns.create_column(
                 board,
                 %{
                   "name" => "From Strings",
                   "totally_unknown_field" => 42
                 },
                 user
               )
    end

    test "rejects negative wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:error, changeset} =
               Columns.create_column(board, %{name: "Test", wip_limit: -1}, user)

      assert "must be greater than or equal to 0" in errors_on(changeset).wip_limit
    end

    test "accepts wip_limit of 0" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Test", wip_limit: 0}, user)

      assert column.wip_limit == 0
    end

    test "accepts positive wip_limit" do
      user = user_fixture()
      board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(board, %{name: "Test", wip_limit: 10}, user)

      assert column.wip_limit == 10
    end

    test "ignores a caller-supplied board_id and uses the trusted board (D93)" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)

      assert {:ok, %Column{} = column} =
               Columns.create_column(
                 board,
                 %{
                   name: "Sneaky",
                   board_id: other_board.id
                 },
                 user
               )

      assert column.board_id == board.id
      refute column.board_id == other_board.id
    end
  end

  describe "column name length" do
    test "create_column/3 and update_column/3 refuse a name over 255 characters" do
      user = user_fixture()
      board = board_fixture(user)
      too_long = String.duplicate("é", 256)

      assert {:error, changeset} = Columns.create_column(board, %{name: too_long}, user)
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)

      column = column_fixture(board, %{name: "Short"})
      assert {:error, changeset} = Columns.update_column(column, %{name: too_long}, user)
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "a name of exactly 255 characters is kept" do
      user = user_fixture()
      board = board_fixture(user)
      name = String.duplicate("é", 255)

      assert {:ok, %Column{name: ^name}} = Columns.create_column(board, %{name: name}, user)
    end
  end

  describe "update_column/3" do
    test "updates the column with valid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Old Name"})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(column, %{name: "New Name"}, user)

      assert updated_column.name == "New Name"
      assert updated_column.id == column.id
    end

    test "updates wip_limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 5})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(column, %{wip_limit: 10}, user)

      assert updated_column.wip_limit == 10
    end

    test "rejects negative wip_limit on update" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:error, changeset} =
               Columns.update_column(column, %{wip_limit: -5}, user)

      assert "must be greater than or equal to 0" in errors_on(changeset).wip_limit
    end

    test "returns error with invalid attributes" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:error, %Ecto.Changeset{}} =
               Columns.update_column(column, %{name: nil}, user)
    end

    test "cannot reassign board_id from params (D93)" do
      user = user_fixture()
      board = board_fixture(user)
      other_board = board_fixture(user)
      column = column_fixture(board, %{name: "Stays Put"})

      assert {:ok, %Column{} = updated_column} =
               Columns.update_column(
                 column,
                 %{
                   name: "Renamed",
                   board_id: other_board.id
                 },
                 user
               )

      assert updated_column.name == "Renamed"
      assert updated_column.board_id == board.id
      refute updated_column.board_id == other_board.id
    end
  end

  describe "delete_column/2" do
    test "deletes the column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:ok, %Column{}} = Columns.delete_column(column, user)
      assert_raise Ecto.NoResultsError, fn -> Columns.get_column!(column.id) end
    end

    test "reorders remaining columns after deletion" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      # Delete the middle column
      {:ok, _deleted} = Columns.delete_column(column2, user)

      # Refresh columns from database
      remaining_columns = Columns.list_columns(board)

      assert length(remaining_columns) == 2
      assert Enum.at(remaining_columns, 0).id == column1.id
      assert Enum.at(remaining_columns, 0).position == 0
      assert Enum.at(remaining_columns, 1).id == column3.id
      assert Enum.at(remaining_columns, 1).position == 1
    end

    test "reorders when deleting first column" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      {:ok, _deleted} = Columns.delete_column(column1, user)

      remaining_columns = Columns.list_columns(board)

      assert length(remaining_columns) == 2
      assert Enum.at(remaining_columns, 0).id == column2.id
      assert Enum.at(remaining_columns, 0).position == 0
      assert Enum.at(remaining_columns, 1).id == column3.id
      assert Enum.at(remaining_columns, 1).position == 1
    end

    test "does not affect other board's columns" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)

      column1 = column_fixture(board1)
      column2 = column_fixture(board2)

      {:ok, _deleted} = Columns.delete_column(column1, user)

      # Board2's column should be unaffected
      assert Columns.get_column!(column2.id).position == 0
    end
  end

  describe "D140: create_column/update_column owner authorization" do
    setup do
      owner = user_fixture()
      stranger = user_fixture()
      modify_user = user_fixture()
      board = board_fixture(owner)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, modify_user, :modify, owner)
      column = column_fixture(board, %{name: "Guarded"})
      %{owner: owner, stranger: stranger, modify_user: modify_user, board: board, column: column}
    end

    test "create_column is rejected for a stranger", %{board: board, stranger: stranger} do
      assert {:error, :unauthorized} =
               Columns.create_column(board, %{name: "Sneaky"}, stranger)
    end

    test "create_column is rejected for a non-owner :modify collaborator", %{
      board: board,
      modify_user: modify_user
    } do
      assert {:error, :unauthorized} =
               Columns.create_column(board, %{name: "Sneaky"}, modify_user)
    end

    test "update_column is rejected for a stranger", %{column: column, stranger: stranger} do
      assert {:error, :unauthorized} =
               Columns.update_column(column, %{name: "Hacked"}, stranger)
    end

    test "update_column is rejected for a non-owner :modify collaborator", %{
      column: column,
      modify_user: modify_user
    } do
      assert {:error, :unauthorized} =
               Columns.update_column(column, %{name: "Hacked"}, modify_user)
    end

    test "both succeed for the board owner", %{board: board, column: column, owner: owner} do
      assert {:ok, %Column{}} = Columns.create_column(board, %{name: "Allowed"}, owner)
      assert {:ok, %Column{}} = Columns.update_column(column, %{name: "Renamed"}, owner)
    end
  end

  describe ":columns_changed broadcast" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      %{user: user, board: board}
    end

    test "create, update, reorder and delete each broadcast the board id", %{
      user: user,
      board: board
    } do
      board_id = board.id

      {:ok, first} = Columns.create_column(board, %{name: "First"}, user)
      assert_receive {Columns, :columns_changed, ^board_id}

      {:ok, second} = Columns.create_column(board, %{name: "Second"}, user)
      assert_receive {Columns, :columns_changed, ^board_id}

      {:ok, _} = Columns.update_column(first, %{name: "Renamed"}, user)
      assert_receive {Columns, :columns_changed, ^board_id}

      :ok = Columns.reorder_columns(board, [second.id, first.id], user)
      assert_receive {Columns, :columns_changed, ^board_id}

      {:ok, _} = Columns.delete_column(second, user)
      assert_receive {Columns, :columns_changed, ^board_id}
    end

    test "a refused or invalid write broadcasts nothing", %{user: user, board: board} do
      column = column_fixture(board)
      flush_columns_changed()
      outsider = user_fixture()

      assert {:error, :unauthorized} = Columns.create_column(board, %{name: "X"}, outsider)
      assert {:error, :unauthorized} = Columns.update_column(column, %{name: "Y"}, outsider)
      assert {:error, %Ecto.Changeset{}} = Columns.update_column(column, %{name: nil}, user)

      refute_receive {Columns, :columns_changed, _}, 50
    end

    defp flush_columns_changed do
      receive do
        {Columns, :columns_changed, _} -> flush_columns_changed()
      after
        0 -> :ok
      end
    end
  end

  describe "reorder_columns/3" do
    test "reorders columns based on list of IDs" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board, %{name: "First"})
      column2 = column_fixture(board, %{name: "Second"})
      column3 = column_fixture(board, %{name: "Third"})

      # Reorder: Third, First, Second
      Columns.reorder_columns(board, [column3.id, column1.id, column2.id], user)

      columns = Columns.list_columns(board)

      assert Enum.at(columns, 0).id == column3.id
      assert Enum.at(columns, 0).position == 0
      assert Enum.at(columns, 1).id == column1.id
      assert Enum.at(columns, 1).position == 1
      assert Enum.at(columns, 2).id == column2.id
      assert Enum.at(columns, 2).position == 2
    end

    test "handles partial reordering" do
      user = user_fixture()
      board = board_fixture(user)

      column1 = column_fixture(board)
      column2 = column_fixture(board)

      # Swap them
      Columns.reorder_columns(board, [column2.id, column1.id], user)

      columns = Columns.list_columns(board)

      assert Enum.at(columns, 0).id == column2.id
      assert Enum.at(columns, 1).id == column1.id
    end
  end

  describe "column telemetry" do
    @created [:kanban, :column, :created]
    @updated [:kanban, :column, :updated]
    @deleted [:kanban, :column, :deleted]
    @reordered [:kanban, :column, :reordered]
    @column_events [@created, @updated, @deleted, @reordered]

    test "create_column emits column.created" do
      owner = user_fixture()
      board = board_fixture(owner)
      attach_telemetry(@column_events)

      assert {:ok, column} = Columns.create_column(board, %{name: "Private name"}, owner)

      assert_received {:telemetry_event, @created, %{count: 1}, metadata}
      assert metadata == %{board_id: board.id, column_id: column.id, actor_user_id: owner.id}
    end

    test "an invalid or refused create emits nothing" do
      owner = user_fixture()
      stranger = user_fixture()
      board = board_fixture(owner)
      attach_telemetry(@column_events)

      assert {:error, %Ecto.Changeset{}} = Columns.create_column(board, %{name: nil}, owner)
      assert {:error, :unauthorized} = Columns.create_column(board, %{name: "X"}, stranger)
      refute_received {:telemetry_event, _, _, _}
    end

    test "update_column emits the changed field names and no values" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      attach_telemetry(@column_events)

      assert {:ok, _} = Columns.update_column(column, %{name: "Secret rename"}, owner)

      assert_received {:telemetry_event, @updated, %{count: 1}, metadata}

      assert metadata == %{
               board_id: board.id,
               column_id: column.id,
               actor_user_id: owner.id,
               fields: [:name]
             }

      refute inspect(metadata) =~ "Secret rename"
    end

    test "a no-op column update emits nothing" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      attach_telemetry(@column_events)

      assert {:ok, _} = Columns.update_column(column, %{name: column.name}, owner)
      refute_received {:telemetry_event, _, _, _}
    end

    test "invalid column update emits nothing" do
      owner = user_fixture()
      stranger = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      attach_telemetry(@column_events)

      assert {:error, %Ecto.Changeset{}} = Columns.update_column(column, %{name: nil}, owner)
      assert {:error, :unauthorized} = Columns.update_column(column, %{name: "X"}, stranger)
      refute_received {:telemetry_event, _, _, _}
    end

    test "delete_column emits column.deleted with the acting user" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      attach_telemetry(@column_events)

      assert {:ok, _} = Columns.delete_column(column, owner)

      assert_received {:telemetry_event, @deleted, %{count: 1}, metadata}
      assert metadata == %{board_id: board.id, column_id: column.id, actor_user_id: owner.id}
      assert Columns.list_columns(board) == []
    end

    test "deleting a column that still holds tasks emits column.deleted" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      task_fixture(column)
      attach_telemetry(@column_events)

      assert {:ok, _} = Columns.delete_column(column, owner)

      assert_received {:telemetry_event, @deleted, %{count: 1},
                       %{column_id: column_id, actor_user_id: actor_id}}

      assert column_id == column.id
      assert actor_id == owner.id
      refute_received {:telemetry_event, @deleted, _, _}
    end

    test "reorder_columns emits column.reordered with the column count and the acting user" do
      owner = user_fixture()
      board = board_fixture(owner)
      [c1, c2, c3] = for _ <- 1..3, do: column_fixture(board)
      attach_telemetry(@column_events)

      assert :ok = Columns.reorder_columns(board, [c3.id, c1.id, c2.id], owner)

      assert_received {:telemetry_event, @reordered, %{count: 1, column_count: 3}, metadata}
      assert metadata == %{board_id: board.id, actor_user_id: owner.id}
    end

    test "reorder_columns with a partial or empty id list still emits the supplied count and the actor" do
      owner = user_fixture()
      board = board_fixture(owner)
      [_c1, c2] = for _ <- 1..2, do: column_fixture(board)
      expected = %{board_id: board.id, actor_user_id: owner.id}
      attach_telemetry(@column_events)

      assert :ok = Columns.reorder_columns(board, [c2.id], owner)
      assert_received {:telemetry_event, @reordered, %{count: 1, column_count: 1}, ^expected}

      assert :ok = Columns.reorder_columns(board, [], owner)
      assert_received {:telemetry_event, @reordered, %{count: 1, column_count: 0}, ^expected}
    end

    test "the actor-less delete_column/1 and reorder_columns/2 no longer exist" do
      Code.ensure_loaded!(Columns)

      assert function_exported?(Columns, :delete_column, 2)
      assert function_exported?(Columns, :reorder_columns, 3)
      refute function_exported?(Columns, :delete_column, 1)
      refute function_exported?(Columns, :reorder_columns, 2)
    end

    test "creating an AI board emits column.created for each default column" do
      owner = user_fixture()
      attach_telemetry(@created)

      {:ok, board} = Kanban.Boards.create_ai_optimized_board(owner, %{name: "AI board"})

      for column <- board.columns do
        column_id = column.id
        assert_received {:telemetry_event, @created, %{count: 1}, %{column_id: ^column_id}}
      end

      assert length(board.columns) == 5
    end
  end
end
