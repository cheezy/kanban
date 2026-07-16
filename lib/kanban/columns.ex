defmodule Kanban.Columns do
  @moduledoc """
  The Columns context.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards
  alias Kanban.Boards.Board
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
  Returns a column scoped to a board, or `nil` if it does not exist or
  belongs to a different board.

  Used by authorization-sensitive callers that must not trust a
  client-supplied column id without verifying it belongs to the current
  board (e.g. drag-and-drop handlers that receive both old and new
  column ids).
  """
  def get_column_for_board(id, board_id) do
    Repo.get_by(Column, id: id, board_id: board_id)
  end

  @doc """
  Creates a column for a board with automatic position assignment.

  Only the board owner may create columns; any other user gets
  `{:error, :unauthorized}`. Columns are owner-only everywhere else
  (delete/move and the modal `handle_params` gates), so this check makes the
  context authoritative rather than relying solely on the mount-time
  redirect (defense-in-depth, W1677 L1 / D140).

  ## Examples

      iex> create_column(board, %{name: "To Do"}, owner)
      {:ok, %Column{}}

      iex> create_column(board, %{name: nil}, owner)
      {:error, %Ecto.Changeset{}}

      iex> create_column(board, %{name: "To Do"}, non_owner)
      {:error, :unauthorized}

  """
  def create_column(board, attrs, user) do
    if Boards.owner?(board, user) do
      # Normalize every caller-supplied key to a string. Ecto.Changeset.cast/3
      # rejects mixed atom/string-keyed maps but is happy with a fully
      # string-keyed map — it matches each entry against the allowed-fields
      # list internally and silently ignores unknown fields. Earlier versions
      # of this function used String.to_existing_atom on every caller-supplied
      # string key, which raised ArgumentError on any unexpected key and
      # surfaced as a 500 instead of a controlled changeset error.
      attrs =
        attrs
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
        |> Map.put("position", get_next_position(board))

      %Column{board_id: board.id}
      |> Column.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates a column.

  Only the board owner may update columns; any other user gets
  `{:error, :unauthorized}` (defense-in-depth, W1677 L1 / D140).

  ## Examples

      iex> update_column(column, %{name: "In Progress"}, owner)
      {:ok, %Column{}}

      iex> update_column(column, %{name: nil}, owner)
      {:error, %Ecto.Changeset{}}

      iex> update_column(column, %{name: "In Progress"}, non_owner)
      {:error, :unauthorized}

  """
  def update_column(%Column{} = column, attrs, user) do
    # owner?/2 only reads board.id, so authorizing against a stub struct
    # avoids loading the full board record here.
    if Boards.owner?(%Board{id: column.board_id}, user) do
      column
      |> Column.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
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

    # Decrement the position of each column directly — this internal
    # repositioning runs under delete_column, whose caller already
    # authorized the owner, so it must not re-enter the authorized
    # public update_column/3.
    Enum.each(columns, fn column ->
      column
      |> Column.changeset(%{position: column.position - 1})
      |> Repo.update()
    end)
  end
end
