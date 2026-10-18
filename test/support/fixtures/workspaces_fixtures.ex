defmodule Kanban.WorkspacesFixtures do
  @moduledoc """
  This module defines test helpers for creating `Kanban.Workspaces` entities.

  Personal workspaces go through the context, so they always get their owner
  row. Org workspaces and memberships are inserted straight through the schema
  changesets — the same non-casting paths the context uses — so a fixture needs
  no org-admin.
  """

  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @doc """
  Creates `user`'s personal workspace with its owner row.
  """
  def personal_workspace_fixture(user) do
    {:ok, workspace} = Workspaces.create_personal_workspace(user)
    workspace
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
