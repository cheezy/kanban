defmodule Kanban.OrganizationsFixtures do
  @moduledoc """
  This module defines test helpers for creating `Kanban.Organizations`
  entities.

  Organizations are inserted straight through the changeset, so a fixture
  needs no site admin and emits no telemetry or audit event. Memberships go
  through `OrganizationMember.changeset/3`, the same non-casting path the
  context uses.
  """

  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  def valid_organization_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Organization #{System.unique_integer([:positive])}",
      contact_name: "Pat Contact",
      contact_email: "contact#{System.unique_integer([:positive])}@example.com"
    })
  end

  def organization_fixture(attrs \\ %{}) do
    %Organization{}
    |> Organization.changeset(valid_organization_attributes(attrs))
    |> Repo.insert!()
  end

  @doc """
  Makes `user` a member of `organization` with `role` (`:member` by default).
  """
  def organization_member_fixture(organization, user, role \\ :member) do
    organization.id
    |> OrganizationMember.changeset(user.id, role)
    |> Repo.insert!()
  end
end
