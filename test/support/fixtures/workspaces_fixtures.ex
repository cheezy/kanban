defmodule Kanban.WorkspacesFixtures do
  @moduledoc """
  This module defines test helpers for creating `Kanban.Workspaces` entities.

  Personal workspaces go through the context, so they always get their owner
  row. Org workspaces and memberships are inserted straight through the schema
  changesets — the same non-casting paths the context uses — so a fixture needs
  no org-admin.
  """

  import Ecto.Query, only: [where: 3]

  alias Kanban.AccountsFixtures
  alias Kanban.Boards.Board
  alias Kanban.BoardsFixtures
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @doc """
  Returns `user`'s personal workspace, creating it with its owner row when the
  user has none. Users registered through `Kanban.Accounts.register_user/1`
  (every `user_fixture/1`) already have one.
  """
  def personal_workspace_fixture(user) do
    {:ok, workspace} = Workspaces.ensure_personal_workspace(user)
    workspace
  end

  @doc """
  Deletes `user`'s personal workspace and its owner row, leaving the user as it
  was before personal workspaces existed. Boards must not be in it yet.
  """
  def remove_personal_workspace(user) do
    case Workspaces.get_personal_workspace(user) do
      nil -> :ok
      workspace -> Repo.delete!(workspace)
    end

    user
  end

  @doc """
  Creates a board owned by a new user and moves it into `workspace`, giving
  the workspace's members no board_users row on it — as the W2217 backfill did
  for memberless boards. `Kanban.Boards.user_has_boards?/1` reads only
  board_users, so it does not see such a board. Returns the board.
  """
  def place_board_in_workspace(workspace) do
    board = BoardsFixtures.board_fixture(AccountsFixtures.user_fixture())

    {1, _} =
      Board |> where([b], b.id == ^board.id) |> Repo.update_all(set: [workspace_id: workspace.id])

    %{board | workspace_id: workspace.id}
  end

  @doc """
  Creates an org workspace for `organization`. Pass `archived_at:` in `attrs` to
  create it archived.
  """
  def org_workspace_fixture(organization, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "Workspace #{System.unique_integer([:positive])}"})

    attrs
    |> Workspace.create_changeset(false, organization.id)
    |> Ecto.Changeset.change(archived_at: attrs[:archived_at])
    |> Repo.insert!()
  end

  @doc """
  Gives `user` a `role` row (`:member` by default) on `workspace`.
  """
  def workspace_member_fixture(workspace, user, role \\ :member) do
    workspace.id
    |> WorkspaceMember.changeset(user.id, role)
    |> Repo.insert!()
  end
end
