defmodule Kanban.Columns do
  @moduledoc """
  The Columns context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo

  @doc """
  Returns the list of columns for a board, ordered by position.

  ## Examples

      iex> list_columns(board)
      [%Column{}, ...]

  """
  def list_columns(board) do
    Column
    |> where([c], c.board_id == ^board.id)
    |> order_by([c], c.position)
    |> Repo.all()
  end

  @doc """
  Gets a single column.

  Raises `Ecto.NoResultsError` if the Column does not exist.

  ## Examples

      iex> get_column!(123)
      %Column{}

      iex> get_column!(456)
      ** (Ecto.NoResultsError)

  """
  def get_column!(id), do: Repo.get!(Column, id)

  @doc """
  Creates a column for a board with automatic position assignment.

  ## Examples

      iex> create_column(board, %{name: "To Do"})
      {:ok, %Column{}}

      iex> create_column(board, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_column(board, attrs \\ %{}) do
    # Get the next position
    next_position = get_next_position(board)

    # Handle both string and atom keys
    attrs =
      case attrs do
        %{} = map when is_map_key(map, "name") or is_map_key(map, :name) ->
          # Convert to atom keys if needed, then add position
          attrs
          |> Enum.into(%{}, fn
            {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
            {k, v} -> {k, v}
          end)
          |> Map.put(:position, next_position)

        _ ->
          Map.put(attrs, :position, next_position)
      end

    %Column{board_id: board.id}
    |> Column.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a column.

  ## Examples

      iex> update_column(column, %{name: "In Progress"})
      {:ok, %Column{}}

      iex> update_column(column, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_column(%Column{} = column, attrs) do
    column
    |> Column.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a column and reorders the remaining columns.

  ## Examples

      iex> delete_column(column)
      {:ok, %Column{}}

      iex> delete_column(column)
      {:error, %Ecto.Changeset{}}

  """
  def delete_column(%Column{} = column) do
    result = Repo.delete(column)

    # Reorder remaining columns after deletion
    case result do
      {:ok, deleted_column} ->
        reorder_after_deletion(deleted_column)
        {:ok, deleted_column}

      error ->
        error
    end
  end

  @doc """
  Reorders columns for a board based on a list of column IDs.

  ## Examples

      iex> reorder_columns(board, [3, 1, 2])
      :ok

  """
  def reorder_columns(board, column_ids) do
    # Use a transaction to handle the unique constraint on (board_id, position)
    Repo.transaction(fn ->
      # First, set all positions to large negative values based on ID to avoid constraint violations
      columns = list_columns(board)

      Enum.each(columns, fn column ->
        Column
        |> where([c], c.id == ^column.id)
        |> Repo.update_all(set: [position: -1 * column.id])
      end)

      # Then update each column with its new position
      column_ids
      |> Enum.with_index()
      |> Enum.each(fn {column_id, index} ->
        Column
        |> where([c], c.id == ^column_id and c.board_id == ^board.id)
        |> Repo.update_all(set: [position: index])
      end)
    end)

    :ok
  end

  # Private functions

  defp get_next_position(board) do
    query =
      from c in Column,
        where: c.board_id == ^board.id,
        select: max(c.position)

    case Repo.one(query) do
      nil -> 0
      max_position -> max_position + 1
    end
  end

  defp reorder_after_deletion(deleted_column) do
    # Get all columns after the deleted position
    query =
      from c in Column,
        where: c.board_id == ^deleted_column.board_id,
        where: c.position > ^deleted_column.position,
        order_by: c.position

    columns = Repo.all(query)

    # Decrement the position of each column
    Enum.each(columns, fn column ->
      update_column(column, %{position: column.position - 1})
    end)
  end
end
