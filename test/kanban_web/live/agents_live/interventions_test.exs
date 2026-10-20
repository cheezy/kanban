defmodule KanbanWeb.AgentsLive.InterventionsTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias KanbanWeb.AgentsLive.Interventions

  describe "build_reassign_state/1 (D385)" do
    test "offers enabled board members as owners and leaves disabled accounts out" do
      members = [
        %{user: %User{id: 1, name: "Ada", email: "ada@example.test", disabled_at: nil}},
        %{
          user: %User{
            id: 2,
            name: "Gone",
            email: "gone@example.test",
            disabled_at: ~U[2026-10-01 00:00:00Z]
          }
        },
        %{user: %User{id: 3, name: nil, email: "eve@example.test", disabled_at: nil}}
      ]

      state = Interventions.build_reassign_state(%{goal: :goal, children: [], members: members})

      assert state.member_options == [{"Ada", 1}, {"eve@example.test", 3}]
      assert state.goal == :goal
    end
  end
end
