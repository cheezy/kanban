defmodule KanbanWeb.TaskLive.Form.SaveTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.Form.Save
  alias KanbanWeb.TaskLive.FormComponent

  defp form_socket(user, board, column) do
    {:ok, socket} =
      FormComponent.update(
        %{
          current_scope: %{user: user},
          task: %Tasks.Task{column_id: column.id},
          board: board,
          action: :new_task,
          column_id: column.id,
          patch: "/boards/#{board.id}"
        },
        %Phoenix.LiveView.Socket{}
      )

    Map.update!(socket, :assigns, &Map.put(&1, :flash, %{}))
  end

  describe "save/2" do
    test "creates the task for a member with modify access and tells the board" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      assert {:noreply, socket} =
               user |> form_socket(board, column) |> Save.save(%{"title" => "Saved here"})

      assert socket.assigns.flash["info"] == "Task created successfully"
      assert %Tasks.Task{id: id} = Repo.get_by(Tasks.Task, title: "Saved here")
      assert_received {FormComponent, {:saved, %Tasks.Task{id: ^id}}}
    end

    test "refuses a read-only member and saves nothing (D110)" do
      owner = user_fixture()
      board = board_fixture(owner)
      column = column_fixture(board)
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

      assert {:noreply, socket} =
               reader |> form_socket(board, column) |> Save.save(%{"title" => "Not saved"})

      assert socket.assigns.flash["error"] ==
               "You do not have permission to modify tasks on this board"

      refute Repo.get_by(Tasks.Task, title: "Not saved")
      refute_received {FormComponent, _}
    end
  end
end
