defmodule Kanban.Boards.BoardTelemetryTest do
  use ExUnit.Case, async: true

  import Kanban.TelemetryHelpers

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser

  @actor %{id: 9}
  @board %Board{id: 4, field_visibility: %{"complexity" => false, "key_files" => true}}
  @events [
    [:kanban, :board, :updated],
    [:kanban, :board, :deleted],
    [:kanban, :board, :field_visibility_changed],
    [:kanban, :board, :member_added],
    [:kanban, :board, :member_removed],
    [:kanban, :board, :member_access_changed],
    [:kanban, :board, :member_cap_reached],
    [:kanban, :api, :token_bulk_revoked]
  ]

  setup do
    attach_telemetry(@events)
    :ok
  end

  test "error results pass through unchanged and emit nothing" do
    changeset = Ecto.Changeset.change(@board, name: "Other")
    error = {:error, changeset}

    assert BoardTelemetry.updated(error, changeset, @actor) == error
    assert BoardTelemetry.deleted({:error, :unauthorized}, @actor) == {:error, :unauthorized}
    assert BoardTelemetry.field_visibility_changed(error, changeset, @actor) == error
    refute_received {:telemetry_event, _, _, _}
  end

  describe "member_cap_reached/4" do
    test "emits board_id, actor_user_id and via for a cap refusal and returns it" do
      for via <- [:direct_add, :invitation, :board_move] do
        result = {:error, :member_cap_reached}
        assert BoardTelemetry.member_cap_reached(result, @board, via, @actor) == result

        assert_received {:telemetry_event, [:kanban, :board, :member_cap_reached], %{count: 1},
                         metadata}

        assert metadata == %{board_id: 4, actor_user_id: 9, via: via}
      end
    end

    test "passes any other result through and emits nothing" do
      for result <- [{:ok, %BoardUser{}}, {:error, :unauthorized}, {:error, :not_found}] do
        assert BoardTelemetry.member_cap_reached(result, @board, :direct_add, @actor) == result
      end

      refute_received {:telemetry_event, _, _, _}
    end

    test "raises for a via outside the three addition paths" do
      for via <- [:api, :direct_add_typo, nil] do
        assert_raise FunctionClauseError, fn ->
          BoardTelemetry.member_cap_reached({:error, :member_cap_reached}, @board, via, @actor)
        end
      end

      refute_received {:telemetry_event, _, _, _}
    end
  end

  test "updated returns the result it was given" do
    changeset = Ecto.Changeset.change(@board, name: "Other")
    result = {:ok, @board}

    assert BoardTelemetry.updated(result, changeset, @actor) == result

    assert_received {:telemetry_event, [:kanban, :board, :updated], %{count: 1},
                     %{board_id: 4, actor_user_id: 9, fields: [:name]}}
  end

  test "field_visibility_changed lists only the toggled fields" do
    new = %{"complexity" => true, "key_files" => true}
    changeset = Ecto.Changeset.change(@board, field_visibility: new)

    assert {:ok, @board} =
             BoardTelemetry.field_visibility_changed({:ok, @board}, changeset, @actor)

    assert_received {:telemetry_event, [:kanban, :board, :field_visibility_changed], %{count: 1},
                     %{board_id: 4, actor_user_id: 9, fields: ["complexity"]}}
  end

  test "field_visibility_changed does not raise when the old or new map is nil" do
    nil_board = %Board{id: 4, field_visibility: nil}
    changeset = Ecto.Changeset.change(nil_board, field_visibility: %{"complexity" => true})

    assert {:ok, ^nil_board} =
             BoardTelemetry.field_visibility_changed({:ok, nil_board}, changeset, @actor)

    assert_received {:telemetry_event, [:kanban, :board, :field_visibility_changed], _,
                     %{fields: ["complexity"]}}

    cleared = Ecto.Changeset.change(@board, field_visibility: nil)

    assert {:ok, @board} =
             BoardTelemetry.field_visibility_changed({:ok, @board}, cleared, @actor)

    assert_received {:telemetry_event, [:kanban, :board, :field_visibility_changed], _,
                     %{fields: ["complexity", "key_files"]}}
  end

  test "an unchanged access save without the read_only level emits nothing" do
    board_user = %BoardUser{board_id: 4, user_id: 5, access: :modify}

    assert :ok = BoardTelemetry.membership_changed(board_user, :unchanged, 0, @actor)
    refute_received {:telemetry_event, _, _, _}
  end

  test "an unknown change emits nothing" do
    board_user = %BoardUser{board_id: 4, user_id: 5, access: :modify}

    assert :ok = BoardTelemetry.membership_changed(board_user, :something_else, 0, @actor)
    refute_received {:telemetry_event, _, _, _}
  end
end
