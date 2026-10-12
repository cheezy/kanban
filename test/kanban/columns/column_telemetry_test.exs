defmodule Kanban.Columns.ColumnTelemetryTest do
  use ExUnit.Case, async: true

  import Kanban.TelemetryHelpers

  alias Kanban.Columns.Column
  alias Kanban.Columns.ColumnTelemetry

  @actor %{id: 9}
  @column %Column{id: 3, board_id: 4, name: "Doing"}
  @events [
    [:kanban, :column, :created],
    [:kanban, :column, :updated],
    [:kanban, :column, :deleted],
    [:kanban, :column, :reordered]
  ]

  setup do
    attach_telemetry(@events)
    :ok
  end

  test "error results pass through unchanged and emit nothing" do
    changeset = Ecto.Changeset.change(@column, name: "Done")
    error = {:error, changeset}

    assert ColumnTelemetry.created(error, @actor) == error
    assert ColumnTelemetry.updated(error, changeset, @actor) == error
    assert ColumnTelemetry.deleted(error) == error
    assert ColumnTelemetry.reordered({:error, :rollback}, %{id: 4}, [1, 2]) == :ok
    refute_received {:telemetry_event, _, _, _}
  end

  test "successful results pass through unchanged" do
    changeset = Ecto.Changeset.change(@column, wip_limit: 3)

    assert ColumnTelemetry.created({:ok, @column}, @actor) == {:ok, @column}
    assert ColumnTelemetry.updated({:ok, @column}, changeset, @actor) == {:ok, @column}
    assert ColumnTelemetry.deleted({:ok, @column}) == {:ok, @column}
    assert ColumnTelemetry.reordered({:ok, nil}, %{id: 4}, [1, 2]) == :ok

    assert_received {:telemetry_event, [:kanban, :column, :created], _, %{column_id: 3}}

    assert_received {:telemetry_event, [:kanban, :column, :updated], _,
                     %{column_id: 3, fields: [:wip_limit]}}

    assert_received {:telemetry_event, [:kanban, :column, :deleted], _, %{column_id: 3}}

    assert_received {:telemetry_event, [:kanban, :column, :reordered],
                     %{count: 1, column_count: 2}, %{board_id: 4}}
  end
end
