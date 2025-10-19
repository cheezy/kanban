defmodule Kanban.Boards do
  @moduledoc """
  The Boards context.
  """

  import Ecto.Query, warn: false
  alias Kanban.Repo

  alias Kanban.Boards.Board

  @doc """
  Returns the list of boards for a given user.

  ## Examples

      iex> list_boards(user)
      [%Board{}, ...]

  """
  def list_boards(user) do
    Board
    |> where([b], b.user_id == ^user.id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single board with authorization check.

  Raises `Ecto.NoResultsError` if the Board does not exist or doesn't belong to the user.

  ## Examples

      iex> get_board!(123, user)
      %Board{}

      iex> get_board!(456, user)
      ** (Ecto.NoResultsError)

  """
  def get_board!(id, user) do
    Board
    |> where([b], b.id == ^id and b.user_id == ^user.id)
    |> Repo.one!()
  end

  @doc """
  Creates a board for the given user.

  ## Examples

      iex> create_board(user, %{name: "My Board"})
      {:ok, %Board{}}

      iex> create_board(user, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_board(user, attrs \\ %{}) do
    %Board{}
    |> Board.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:user, user)
    |> Repo.insert()
  end

  @doc """
  Updates a board.

  ## Examples

      iex> update_board(board, %{name: "New Name"})
      {:ok, %Board{}}

      iex> update_board(board, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_board(%Board{} = board, attrs) do
    board
    |> Board.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a board.

  ## Examples

      iex> delete_board(board)
      {:ok, %Board{}}

      iex> delete_board(board)
      {:error, %Ecto.Changeset{}}

  """
  def delete_board(%Board{} = board) do
    Repo.delete(board)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking board changes.

  ## Examples

      iex> change_board(board)
      %Ecto.Changeset{data: %Board{}}

  """
  def change_board(%Board{} = board, attrs \\ %{}) do
    Board.changeset(board, attrs)
  end
end
