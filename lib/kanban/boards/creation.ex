defmodule Kanban.Boards.Creation do
  @moduledoc """
  Board creation: the board row, its owner `board_users` row and the caller's
  personal workspace, written in one transaction, plus the default columns of
  an AI-optimized board.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.create_board/2` and `Boards.create_ai_optimized_board/2` rather than
  reaching into this module directly.

  The workspace is always the caller's personal one, chosen server-side;
  `Board` changesets never cast `workspace_id`. Each successful creation emits
  `[:kanban, :board, :creation]`.

  Split out of `Kanban.Boards` per the module design guidance in `AGENTS.md`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Workspaces

  @doc """
  Creates a board for the given user with owner access.

  The board goes into the caller's personal workspace, created first when they
  have none yet. The workspace is always chosen here, never read from `attrs`.

  ## Examples

      iex> create_board(user, %{name: "My Board"})
      {:ok, %Board{}}

      iex> create_board(user, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_board(user, attrs \\ %{}) do
    case run_create_board_transaction(user, Board.changeset(%Board{}, attrs)) do
      {:ok, board} ->
        Kanban.Telemetry.emit([:kanban, :board, :creation], %{count: 1}, %{
          board_id: board.id,
          user_id: user.id
        })

        {:ok, board}

      error ->
        error
    end
  end

  # The workspace is the caller's personal one, set server-side; Board
  # changesets never cast `workspace_id`.
  defp run_create_board_transaction(user, board_changeset) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:workspace, fn _repo, _changes ->
      Workspaces.ensure_personal_workspace(user)
    end)
    |> Ecto.Multi.insert(:board, fn %{workspace: workspace} ->
      Ecto.Changeset.change(board_changeset, workspace_id: workspace.id)
    end)
    |> Ecto.Multi.insert(:board_user, fn %{board: board} ->
      owner_board_user_changeset(board, user)
    end)
    |> Repo.transaction()
    |> handle_board_transaction_result()
  end

  defp owner_board_user_changeset(board, user) do
    BoardUser.changeset(%BoardUser{}, %{
      board_id: board.id,
      user_id: user.id,
      access: :owner
    })
  end

  defp handle_board_transaction_result({:ok, %{board: board}}), do: {:ok, board}
  defp handle_board_transaction_result({:error, _step, changeset, _}), do: {:error, changeset}

  @doc """
  Creates an AI-optimized board with default columns: Backlog, Ready, Doing, Review, and Done.
  Sets ai_optimized_board to true. Like `create_board/2`, the board goes into the
  caller's personal workspace.

  ## Examples

      iex> create_ai_optimized_board(user, %{name: "AI Board"})
      {:ok, %Board{}}

  """
  def create_ai_optimized_board(user, attrs \\ %{}) do
    board_changeset =
      %Board{}
      |> Board.changeset(attrs)
      |> Ecto.Changeset.change(ai_optimized_board: true)

    case run_create_board_transaction(user, board_changeset) do
      {:ok, board} -> setup_ai_board_columns(board, user)
      error -> error
    end
  end

  defp setup_ai_board_columns(board, user) do
    alias Kanban.Columns

    default_columns = [
      %{name: "Backlog", wip_limit: 0},
      %{name: "Ready", wip_limit: 0},
      %{name: "Doing", wip_limit: 0},
      %{name: "Review", wip_limit: 0},
      %{name: "Done", wip_limit: 0}
    ]

    Enum.each(default_columns, fn column_attrs ->
      Columns.create_column(board, column_attrs, user)
    end)

    Kanban.Telemetry.emit([:kanban, :board, :creation], %{count: 1}, %{
      board_id: board.id,
      user_id: user.id
    })

    board =
      Repo.preload(board, [columns: from(c in Kanban.Columns.Column, order_by: c.position)],
        force: true
      )

    {:ok, board}
  end
end
