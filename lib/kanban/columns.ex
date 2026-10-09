defmodule Kanban.Columns do
  @moduledoc """
  The Columns context.

  A successful create, update, delete or reorder broadcasts
  `{Kanban.Columns, :columns_changed, board_id}` on the board's
  `"board:<id>"` topic, so every open copy of the board re-renders its
  columns. The message carries only the board id.
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
  Returns the first column (by position) on `board_id` whose name matches
  `name`, ignoring case and surrounding whitespace, or `nil` when the board
  has no such column.

  Column names are not unique on a board, so the lowest-positioned match
  wins. The lookup is always scoped to `board_id`, and the name comparison
  is `named?/2` itself (run over the board's few columns in memory), so the
  two can never disagree about which whitespace or case counts as a match.

  ## Examples

      iex> get_column_by_name(board.id, "ready")
      %Column{name: "Ready"}

      iex> get_column_by_name(board.id, "Nope")
      nil

  """
  def get_column_by_name(board_id, name) when is_binary(name) do
    Column
    |> where([c], c.board_id == ^board_id)
    |> order_by([c], c.position)
    |> Repo.all()
    |> Enum.find(&named?(&1, name))
  end

  def get_column_by_name(_board_id, _name), do: nil

  @doc """
  True when `column`'s name equals `name`, ignoring case and surrounding
  whitespace (`String.trim/1`, so any Unicode whitespace) — the comparison
  `get_column_by_name/2` applies. Pure; runs no query. Anything that is not
  a map with a binary `:name`, or a non-binary `name`, is `false`.

  ## Examples

      iex> named?(%Column{name: " backlog "}, "Backlog")
      true

      iex> named?(%Column{name: "To Do"}, "Backlog")
      false

  """
  def named?(%{name: column_name}, name) when is_binary(column_name) and is_binary(name),
    do: normalize_name(column_name) == normalize_name(name)

  def named?(_column, _name), do: false

  defp normalize_name(name), do: name |> String.trim() |> String.downcase()

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
      |> broadcast_columns_changed(board.id)
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
      |> broadcast_columns_changed(column.board_id)
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
        broadcast_columns_changed({:ok, deleted_column}, deleted_column.board_id)

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

    broadcast_columns_changed({:ok, board}, board.id)
    :ok
  end

  defp broadcast_columns_changed({:ok, _} = result, board_id) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, :columns_changed, board_id}
    )

    result
  end

  defp broadcast_columns_changed(error, _board_id), do: error

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
