defmodule Kanban.Columns.ColumnTelemetry do
  @moduledoc """
  Emits the column telemetry events through `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  a refused or invalid change emits nothing. The functions that take a result
  return it unchanged, so they can sit at the end of a pipe without changing
  what the caller sees.

  Metadata carries ids and field names only, never a column's name or any
  other value. Every event carries the acting user's id as `actor_user_id`.
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
  Emits `[:kanban, :column, :deleted]` when `result` is a deleted column,
  recording `actor` as the acting user. Returns `result`.
  """
  @spec deleted(result, map()) :: result when result: term()
  def deleted({:ok, %Column{} = column} = result, actor) do
    Kanban.Telemetry.emit([:kanban, :column, :deleted], %{count: 1}, %{
      board_id: column.board_id,
      column_id: column.id,
      actor_user_id: actor.id
    })

    result
  end

  def deleted(result, _actor), do: result

  @doc """
  Emits `[:kanban, :column, :reordered]` when the reorder transaction
  committed, recording `actor` as the acting user. `column_count` is the
  number of column ids given. Returns `:ok`.
  """
  @spec reordered(term(), map(), list(), map()) :: :ok
  def reordered({:ok, _changes}, board, column_ids, actor) when is_list(column_ids) do
    Kanban.Telemetry.emit(
      [:kanban, :column, :reordered],
      %{count: 1, column_count: length(column_ids)},
      %{board_id: board.id, actor_user_id: actor.id}
    )
  end

  def reordered(_result, _board, _column_ids, _actor), do: :ok
end
