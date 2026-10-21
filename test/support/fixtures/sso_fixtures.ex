defmodule Kanban.SSOFixtures do
  @moduledoc """
  Test helpers for `Kanban.SSO`: domains, connections and identities, plus the
  stub resolvers the test environment configures (`config/test.exs`), so no
  test touches DNS.

  Rows are inserted straight through their changesets, so a fixture needs no
  org-admin and records no audit event.
  """

  import Ecto.Query

  alias Kanban.Repo
  alias Kanban.SSO.OrganizationDomain
  alias Kanban.SSO.SSOConnection
  alias Kanban.SSO.UserIdentity

  @issuer "https://idp.example.com"

  def issuer, do: @issuer

  @doc "A unique domain under `verified.example`, which the TXT stub answers for."
  def unique_domain, do: "org#{System.unique_integer([:positive])}.verified.example"

  @doc "An unverified domain of `organization`."
  def domain_fixture(organization, domain \\ unique_domain()) do
    organization.id
    |> OrganizationDomain.create_changeset(%{domain: domain})
    |> Repo.insert!()
  end

  @doc "A verified domain of `organization`."
  def verified_domain_fixture(organization, domain \\ unique_domain()) do
    organization
    |> domain_fixture(domain)
    |> OrganizationDomain.verify_changeset(DateTime.utc_now())
    |> Repo.update!()
  end

  @doc "An enabled OIDC connection of `organization`."
  def oidc_connection_fixture(organization, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "issuer" => @issuer,
        "client_id" => "stride-client",
        "client_secret" => "fixture-client-credential",
        "enabled" => true
      })

    %SSOConnection{organization_id: organization.id, protocol: :oidc}
    |> SSOConnection.oidc_changeset(attrs)
    |> Repo.insert!()
  end

  @doc "An identity linking `user` to `subject` at `connection`."
  def identity_fixture(user, connection, subject) do
    user
    |> UserIdentity.new_changeset(connection, subject)
    |> Repo.insert!()
  end

  @doc "The `Kanban.SSO` URL resolver: a fixed table of public and private hosts."
  def resolve("idp.example.com"), do: {:ok, [{93, 184, 216, 34}]}
  def resolve("login.example.com"), do: {:ok, [{93, 184, 216, 35}]}
  def resolve("internal.example.com"), do: {:ok, [{10, 0, 0, 1}]}
  def resolve(_host), do: {:error, :nxdomain}

  defmodule TxtResolver do
    @moduledoc """
    The test TXT resolver. For a name under `verified.example` it answers with
    the expected record of every row claiming that domain, read from the
    database, so verification passes for any Organization that claimed it;
    every other name has no records.
    """
    @behaviour Kanban.SSO.TxtResolver

    @impl true
    def lookup_txt("_stride-verification." <> domain) do
      if String.ends_with?(domain, ".verified.example") do
        tokens =
          from(d in OrganizationDomain,
            where: d.domain == ^domain,
            select: d.verification_token
          )
          |> Repo.all()

        {:ok, Enum.map(tokens, &("stride-verification=" <> &1))}
      else
        {:ok, []}
      end
    end

    def lookup_txt(_name), do: {:ok, []}
  end
end
