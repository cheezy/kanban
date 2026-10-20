defmodule KanbanWeb.TaskLive.Form.OptionBuildersTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias Kanban.Labels.Label
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.Form.OptionBuilders

  describe "build_label_options/1 (W2234)" do
    test "maps each label to an id/name/color option, keeping order" do
      labels = [
        %Label{id: 2, name: "Backend", color: :red, board_id: 1},
        %Label{id: 1, name: "Frontend", color: :blue, board_id: 1}
      ]

      assert OptionBuilders.build_label_options(labels) == [
               %{id: 2, name: "Backend", color: :red},
               %{id: 1, name: "Frontend", color: :blue}
             ]
    end

    test "returns [] for a board with no labels" do
      assert OptionBuilders.build_label_options([]) == []
    end
  end

  describe "build_assignable_users_options/2 (D385)" do
    setup do
      %{
        board_users: [
          %{user: %User{id: 1, name: "Ada", email: "ada@example.test", disabled_at: nil}},
          %{
            user: %User{
              id: 2,
              name: "Gone",
              email: "gone@example.test",
              disabled_at: ~U[2026-10-01 00:00:00Z]
            }
          },
          %{user: %User{id: 3, name: "", email: "eve@example.test", disabled_at: nil}}
        ]
      }
    end

    test "assignable users omit disabled accounts", %{board_users: board_users} do
      assert OptionBuilders.build_assignable_users_options(board_users) == [
               {"Unassigned", nil},
               {"Ada", 1},
               {"eve@example.test", 3}
             ]

      assert OptionBuilders.build_assignable_users_options(board_users, %Task{}) ==
               OptionBuilders.build_assignable_users_options(board_users)
    end

    test "keeps the task's current assignee even when disabled, so a save does not unassign",
         %{board_users: board_users} do
      assert OptionBuilders.build_assignable_users_options(board_users, %Task{assigned_to_id: 2}) ==
               [{"Unassigned", nil}, {"Ada", 1}, {"Gone", 2}, {"eve@example.test", 3}]
    end
  end
end
