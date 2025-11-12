defmodule KanbanWeb.ColumnLive.FormComponentTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Columns
  alias KanbanWeb.ColumnLive.FormComponent

  # Note: Full integration tests for column creation/editing are in board_live_test.exs
  # These tests focus on the component's internal logic

  describe "update/2 for new column" do
    test "initializes form with default values" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.column == column
      assert socket.assigns.action == :new_column
      assert socket.assigns.board == board
      assert socket.assigns.form
      assert socket.assigns.form.source.data == column
    end
  end

  describe "update/2 for edit column" do
    test "initializes form with existing column data" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 5})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.column.id == column.id
      assert socket.assigns.column.name == "To Do"
      assert socket.assigns.column.wip_limit == 5
      assert socket.assigns.action == :edit_column
      assert socket.assigns.form
    end

    test "creates changeset for existing column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "In Progress", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column
          },
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.form.source.valid?
      assert socket.assigns.form.source.data.name == "In Progress"
      assert socket.assigns.form.source.data.wip_limit == 3
    end
  end

  describe "handle_event validate" do
    test "updates changeset on validation for new column" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => "New Column", "wip_limit" => "5"}},
          socket
        )

      assert updated_socket.assigns.form.source.changes.name == "New Column"
      assert updated_socket.assigns.form.source.changes.wip_limit == 5
      assert updated_socket.assigns.form.source.action == :validate
    end

    test "updates changeset on validation for existing column" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "To Do", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => "Updated Name", "wip_limit" => "7"}},
          socket
        )

      assert updated_socket.assigns.form.source.changes.name == "Updated Name"
      assert updated_socket.assigns.form.source.changes.wip_limit == 7
      assert updated_socket.assigns.form.source.action == :validate
    end

    test "shows validation errors for missing name" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => ""}},
          socket
        )

      assert updated_socket.assigns.form.source.action == :validate
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:name]
    end

    test "shows validation errors for negative WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => "Test", "wip_limit" => "-1"}},
          socket
        )

      assert updated_socket.assigns.form.source.action == :validate
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:wip_limit]
    end

    test "accepts zero as valid WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Test", wip_limit: 5})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => "Done", "wip_limit" => "0"}},
          socket
        )

      assert updated_socket.assigns.form.source.changes.wip_limit == 0
      assert updated_socket.assigns.form.source.valid?
    end

    test "accepts positive WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Test", wip_limit: 0})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "validate",
          %{"column" => %{"name" => "In Progress", "wip_limit" => "10"}},
          socket
        )

      assert updated_socket.assigns.form.source.changes.wip_limit == 10
      assert updated_socket.assigns.form.source.valid?
    end
  end

  describe "handle_event save for new column" do
    test "creates column with valid data" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      # Initialize flash map in socket assigns
      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "New Column", "wip_limit" => "5"}},
          socket
        )

      # Column should be created in database
      columns = Columns.list_columns(board)
      assert length(columns) == 1
      assert hd(columns).name == "New Column"
      assert hd(columns).wip_limit == 5

      # Flash message should be set
      assert updated_socket.assigns.flash["info"] == "Column created successfully"
    end

    test "creates column with zero WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "No Limit Column", "wip_limit" => "0"}},
          socket
        )

      columns = Columns.list_columns(board)
      assert length(columns) == 1
      assert hd(columns).name == "No Limit Column"
      assert hd(columns).wip_limit == 0
    end

    test "returns error changeset for missing name" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "", "wip_limit" => "5"}},
          socket
        )

      # Column should not be created
      columns = Columns.list_columns(board)
      assert Enum.empty?(columns)

      # Changeset should have errors
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:name]
    end

    test "returns error changeset for negative WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "Test Column", "wip_limit" => "-1"}},
          socket
        )

      # Column should not be created
      columns = Columns.list_columns(board)
      assert Enum.empty?(columns)

      # Changeset should have errors
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:wip_limit]
    end

    test "assigns correct position automatically" do
      user = user_fixture()
      board = board_fixture(user)

      # Create first column
      column_fixture(board, %{name: "Column 1"})

      # Create second column through form component
      column = %Columns.Column{board_id: board.id}

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :new_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "Column 2", "wip_limit" => "3"}},
          socket
        )

      columns = Columns.list_columns(board)
      assert length(columns) == 2
      assert Enum.at(columns, 0).position == 0
      assert Enum.at(columns, 1).position == 1
      assert Enum.at(columns, 1).name == "Column 2"
    end
  end

  describe "handle_event save for edit column" do
    test "updates column with valid data" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Old Name", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "Updated Name", "wip_limit" => "7"}},
          socket
        )

      # Column should be updated
      updated_column = Columns.get_column!(column.id)
      assert updated_column.name == "Updated Name"
      assert updated_column.wip_limit == 7

      # Flash message should be set
      assert updated_socket.assigns.flash["info"] == "Column updated successfully"
    end

    test "updates only name" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Old Name", wip_limit: 5})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "New Name"}},
          socket
        )

      updated_column = Columns.get_column!(column.id)
      assert updated_column.name == "New Name"
      assert updated_column.wip_limit == 5
    end

    test "updates only WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Column Name", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"wip_limit" => "10"}},
          socket
        )

      updated_column = Columns.get_column!(column.id)
      assert updated_column.name == "Column Name"
      assert updated_column.wip_limit == 10
    end

    test "can set WIP limit to zero" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Test", wip_limit: 5})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"wip_limit" => "0"}},
          socket
        )

      updated_column = Columns.get_column!(column.id)
      assert updated_column.wip_limit == 0
    end

    test "returns error changeset for invalid name" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Valid Name", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => ""}},
          socket
        )

      # Column should not be updated
      unchanged_column = Columns.get_column!(column.id)
      assert unchanged_column.name == "Valid Name"

      # Changeset should have errors
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:name]
    end

    test "returns error changeset for negative WIP limit" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board, %{name: "Test", wip_limit: 3})

      {:ok, socket} =
        FormComponent.update(
          %{
            column: column,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"wip_limit" => "-5"}},
          socket
        )

      # Column should not be updated
      unchanged_column = Columns.get_column!(column.id)
      assert unchanged_column.wip_limit == 3

      # Changeset should have errors
      refute updated_socket.assigns.form.source.valid?
      assert updated_socket.assigns.form.source.errors[:wip_limit]
    end

    test "preserves position when updating" do
      user = user_fixture()
      board = board_fixture(user)
      column1 = column_fixture(board, %{name: "Column 1"})
      column2 = column_fixture(board, %{name: "Column 2"})
      column3 = column_fixture(board, %{name: "Column 3"})

      # Update column2
      {:ok, socket} =
        FormComponent.update(
          %{
            column: column2,
            board: board,
            action: :edit_column,
            patch: "/boards/#{board.id}"
          },
          %Phoenix.LiveView.Socket{}
        )

      socket = Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))

      {:noreply, _updated_socket} =
        FormComponent.handle_event(
          "save",
          %{"column" => %{"name" => "Updated Column 2"}},
          socket
        )

      # Positions should remain unchanged
      updated_column2 = Columns.get_column!(column2.id)
      reloaded_column1 = Columns.get_column!(column1.id)
      reloaded_column3 = Columns.get_column!(column3.id)

      assert reloaded_column1.position == 0
      assert updated_column2.position == 1
      assert reloaded_column3.position == 2
    end
  end
end
