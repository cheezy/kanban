defmodule Kanban.Boards.Creation do
  @moduledoc """
  Board creation: the board row, its owner `board_users` row and the caller's
  personal workspace, written in one transaction, plus the default columns of
  an AI-optimized board.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.create_board/2` and `Boards.create_ai_optimized_board/2` rather than
  reaching into this module directly.

  The workspace is chosen server-side; `Board` changesets never cast
  `workspace_id`. A caller may name a `:workspace` option (the current
  workspace from their scope): the board goes there only when that workspace,
  re-read from the database inside the transaction, is an unarchived org
  workspace the caller is an org-admin or a member of
  (`Kanban.Workspaces.Policy.can_create_board_in?/2`). Otherwise, and without
  the option, it goes into the caller's personal workspace. Each successful
  creation emits `[:kanban, :board, :creation]`.

  Split out of `Kanban.Boards` per the module design guidance in `AGENTS.md`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace

  @doc """
  Creates a board for the given user with owner access.

  The board goes into the workspace named by the `:workspace` option when the
  caller may create boards there (see the moduledoc), else into the caller's
  personal workspace, created first when they have none yet. The workspace is
  always chosen here, never read from `attrs`.

  ## Examples

      iex> create_board(user, %{name: "My Board"})
      {:ok, %Board{}}

      iex> create_board(user, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_board(user, attrs \\ %{}, opts \\ []) do
    case run_create_board_transaction(user, Board.changeset(%Board{}, attrs), opts) do
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

  # The workspace is set server-side; Board changesets never cast
  # `workspace_id`.
  defp run_create_board_transaction(user, board_changeset, opts) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:workspace, fn _repo, _changes ->
      target_workspace(user, Keyword.get(opts, :workspace))
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

  # The requested workspace is re-read under a share lock, so an archive that
  # takes the row's update lock and then checks for boards cannot miss a board
  # created at the same moment. Anything the caller may not create in falls
  # back to their personal workspace.
  defp target_workspace(user, %Workspace{id: id}), do: target_workspace(user, id)

  defp target_workspace(user, id) when is_integer(id) do
    workspace =
      from(w in Workspace,
        where: w.id == ^id and w.personal == false and is_nil(w.archived_at),
        lock: "FOR SHARE"
      )
      |> Repo.one()

    if Policy.can_create_board_in?(user, workspace),
      do: {:ok, workspace},
      else: Workspaces.ensure_personal_workspace(user)
  end

  defp target_workspace(user, _none), do: Workspaces.ensure_personal_workspace(user)

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
  Sets ai_optimized_board to true. The board's workspace is chosen exactly as in
  `create_board/3`.

  ## Examples

      iex> create_ai_optimized_board(user, %{name: "AI Board"})
      {:ok, %Board{}}

  """
  def create_ai_optimized_board(user, attrs \\ %{}, opts \\ []) do
    board_changeset =
      %Board{}
      |> Board.changeset(attrs)
      |> Ecto.Changeset.change(ai_optimized_board: true)

    case run_create_board_transaction(user, board_changeset, opts) do
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
