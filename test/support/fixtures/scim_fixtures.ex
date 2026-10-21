defmodule Kanban.SCIMFixtures do
  @moduledoc """
  Test helpers for `Kanban.SCIM` (W2247). Tokens are inserted straight through
  their changeset, so a fixture needs no org-admin and records no audit event.
  """

  alias Kanban.AccountsFixtures
  alias Kanban.Repo
  alias Kanban.SCIM.ScimToken

  @doc """
  An active SCIM token of `organization`. Returns `{token, plaintext}`.
  """
  def scim_token_fixture(organization, attrs \\ %{}) do
    creator = Map.get_lazy(attrs, :created_by, fn -> AccountsFixtures.user_fixture() end)

    token =
      organization.id
      |> ScimToken.create_changeset(creator.id, %{name: Map.get(attrs, :name, "Okta")})
      |> Repo.insert!()

    {%{token | token: nil}, token.token}
  end
end
