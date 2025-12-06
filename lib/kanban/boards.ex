defmodule Kanban.Boards do
  @moduledoc """
  The Boards context.
  """

  import Ecto.Query, warn: false
  alias Kanban.Repo

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser

  @doc """
  Returns the list of boards for a given user with their access level.

  Each board will have a virtual `:user_access` field containing the user's access level.
  Boards are sorted by access level (owner first, modify second, read_only last),
  then by creation date (most recent first) within each access level.

  ## Examples

      iex> list_boards(user)
      [%Board{user_access: :owner}, ...]

  """
  def list_boards(user) do
    Board
    |> join(:inner, [b], bu in BoardUser, on: bu.board_id == b.id)
    |> where([b, bu], bu.user_id == ^user.id)
    |> select([b, bu], %{b | user_access: bu.access})
    |> Repo.all()
    |> Enum.sort_by(
      fn board ->
        access_priority =
          case board.user_access do
            :owner -> 0
            :modify -> 1
            :read_only -> 2
          end

        {access_priority, NaiveDateTime.to_erl(board.inserted_at)}
      end,
      fn {priority_a, time_a}, {priority_b, time_b} ->
        if priority_a == priority_b do
          time_a >= time_b
        else
          priority_a < priority_b
        end
      end
    )
  end

  @doc """
  Gets a single board with authorization check.

  Raises `Ecto.NoResultsError` if the Board does not exist or user doesn't have access.

  ## Examples

      iex> get_board!(123, user)
      %Board{}

      iex> get_board!(456, user)
      ** (Ecto.NoResultsError)

  """
  def get_board!(id, user) do
    Board
    |> join(:inner, [b], bu in BoardUser, on: bu.board_id == b.id)
    |> where([b, bu], b.id == ^id and bu.user_id == ^user.id)
    |> Repo.one!()
  end

  @doc """
  Gets the access level for a user on a board.

  Returns the access level atom (:owner, :read_only, :modify) or nil if user has no access.

  ## Examples

      iex> get_user_access(board_id, user_id)
      :owner

  """
  def get_user_access(board_id, user_id) do
    case Repo.get_by(BoardUser, board_id: board_id, user_id: user_id) do
      nil -> nil
      board_user -> board_user.access
    end
  end

  @doc """
  Checks if a user has owner access to a board.

  ## Examples

      iex> owner?(board, user)
      true

  """
  def owner?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) == :owner
  end

  @doc """
  Checks if a user can modify a board (owner or modify access).

  ## Examples

      iex> can_modify?(board, user)
      true

  """
  def can_modify?(%Board{id: board_id}, user) do
    get_user_access(board_id, user.id) in [:owner, :modify]
  end

  @doc """
  Creates a board for the given user with owner access.

  ## Examples

      iex> create_board(user, %{name: "My Board"})
      {:ok, %Board{}}

      iex> create_board(user, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_board(user, attrs \\ %{}) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:board, Board.changeset(%Board{}, attrs))
      |> Ecto.Multi.insert(:board_user, fn %{board: board} ->
        BoardUser.changeset(%BoardUser{}, %{
          board_id: board.id,
          user_id: user.id,
          access: :owner
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{board: board}} -> {:ok, board}
        {:error, :board, changeset, _} -> {:error, changeset}
        {:error, :board_user, changeset, _} -> {:error, changeset}
      end

    case result do
      {:ok, board} ->
        :telemetry.execute([:kanban, :board, :creation], %{count: 1}, %{
          board_id: board.id,
          user_id: user.id
        })

        {:ok, board}

      error ->
        error
    end
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

  @doc """
  Adds a user to a board with the specified access level.

  ## Examples

      iex> add_user_to_board(board, user, :read_only)
      {:ok, %BoardUser{}}

  """
  def add_user_to_board(%Board{} = board, user, access)
      when access in [:owner, :read_only, :modify] do
    %BoardUser{}
    |> BoardUser.changeset(%{
      board_id: board.id,
      user_id: user.id,
      access: access
    })
    |> Repo.insert()
  end

  @doc """
  Removes a user from a board.

  ## Examples

      iex> remove_user_from_board(board, user)
      {:ok, %BoardUser{}}

  """
  def remove_user_from_board(%Board{} = board, user) do
    case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
      nil -> {:error, :not_found}
      board_user -> Repo.delete(board_user)
    end
  end

  @doc """
  Updates a user's access level for a board.

  ## Examples

      iex> update_user_access(board, user, :modify)
      {:ok, %BoardUser{}}

  """
  def update_user_access(%Board{} = board, user, new_access)
      when new_access in [:owner, :read_only, :modify] do
    case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      board_user ->
        board_user
        |> BoardUser.changeset(%{access: new_access})
        |> Repo.update()
    end
  end

  @doc """
  Lists all users associated with a board along with their access level.

  Users are sorted by access level (owner first, then modify, then read_only),
  and then alphabetically by email within each access level.

  ## Examples

      iex> list_board_users(board)
      [%{user: %User{}, access: :owner}, ...]

  """
  def list_board_users(%Board{id: board_id}) do
    BoardUser
    |> where([bu], bu.board_id == ^board_id)
    |> join(:inner, [bu], u in assoc(bu, :user))
    |> select([bu, u], %{user: u, access: bu.access})
    |> Repo.all()
    |> Enum.sort_by(fn %{user: user, access: access} ->
      access_priority =
        case access do
          :owner -> 0
          :modify -> 1
          :read_only -> 2
        end

      {access_priority, user.email}
    end)
  end
end
