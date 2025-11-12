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
end
