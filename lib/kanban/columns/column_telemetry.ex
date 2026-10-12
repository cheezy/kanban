defmodule Kanban.Columns.ColumnTelemetry do
  @moduledoc """
  Emits the column telemetry events through `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  a refused or invalid change emits nothing. The functions that take a result
  return it unchanged, so they can sit at the end of a pipe without changing
  what the caller sees.

  Metadata carries ids and field names only, never a column's name or any
  other value. `delete_column/1` and `reorder_columns/2` are not given the
  acting user, so `[:kanban, :column, :deleted]` and
  `[:kanban, :column, :reordered]` carry no `actor_user_id`.
  """

  alias Ecto.Changeset
  alias Kanban.Columns.Column

  @doc """
  Emits `[:kanban, :column, :created]` when `result` is a saved column.
  Returns `result`.
  """
  @spec created(result, map()) :: result when result: term()
  def created({:ok, %Column{} = column} = result, actor) do
    Kanban.Telemetry.emit([:kanban, :column, :created], %{count: 1}, %{
      board_id: column.board_id,
      column_id: column.id,
      actor_user_id: actor.id
    })

    result
  end

  def created(result, _actor), do: result

  @doc """
  Emits `[:kanban, :column, :updated]` when `result` is a saved column and
  the changeset changed at least one field. `fields` lists the changed field
  names, never their values. Returns `result`.
  """
  @spec updated(result, Changeset.t(), map()) :: result when result: term()
  def updated({:ok, %Column{} = column} = result, %Changeset{changes: changes}, actor)
      when map_size(changes) > 0 do
    Kanban.Telemetry.emit([:kanban, :column, :updated], %{count: 1}, %{
      board_id: column.board_id,
      column_id: column.id,
      actor_user_id: actor.id,
      fields: changes |> Map.keys() |> Enum.sort()
    })

    result
  end

  def updated(result, _changeset, _actor), do: result

  @doc """
  Emits `[:kanban, :column, :deleted]` when `result` is a deleted column.
  Returns `result`.
  """
  @spec deleted(result) :: result when result: term()
  def deleted({:ok, %Column{} = column} = result) do
    Kanban.Telemetry.emit([:kanban, :column, :deleted], %{count: 1}, %{
      board_id: column.board_id,
      column_id: column.id
    })

    result
  end

  def deleted(result), do: result

  @doc """
  Emits `[:kanban, :column, :reordered]` when the reorder transaction
  committed. `column_count` is the number of column ids given. Returns `:ok`.
  """
  @spec reordered(term(), map(), list()) :: :ok
  def reordered({:ok, _changes}, board, column_ids) when is_list(column_ids) do
    Kanban.Telemetry.emit(
      [:kanban, :column, :reordered],
      %{count: 1, column_count: length(column_ids)},
      %{board_id: board.id}
    )
  end

  def reordered(_result, _board, _column_ids), do: :ok
end
