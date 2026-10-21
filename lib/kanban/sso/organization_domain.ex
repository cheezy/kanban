defmodule Kanban.SSO.OrganizationDomain do
  @moduledoc """
  An email domain an Organization claims for single sign-on.

  A domain is usable only once `verified_at` is set, which happens when the
  DNS TXT record built from `verification_token` is found
  (`Kanban.SSO.DomainVerification`). Several Organizations may claim the same
  domain, but the partial unique index
  `organization_domains_verified_domain_index` admits one verified row per
  domain, so the first verification wins.

  A verified domain is checked again every day (`Kanban.SSO.DomainRecheck`):
  `failed_checks` counts the consecutive checks that did not find the record
  and `failing_since` is when the first of them ran, both reset when a check
  finds it, and `last_checked_at` is the latest check.

  Managed by `Kanban.SSO`.
  """

  use Ecto.Schema
  use Gettext, backend: KanbanWeb.Gettext

  import Ecto.Changeset

  alias Kanban.Organizations.Organization

  @type t :: %__MODULE__{}

  # ASCII (punycode) hostnames with at least two labels and an alphabetic top
  # label, at most 253 characters, every label 1-63 characters.
  @domain_format ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  schema "organization_domains" do
    belongs_to :organization, Organization
    field :domain, :string
    field :verification_token, :string, redact: true
    field :verified_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :failed_checks, :integer, default: 0
    field :failing_since, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Normalizes a domain the way it is stored: trimmed, lowercased and without a
  trailing dot. Returns `{:ok, domain}` when it is a valid hostname, else
  `:error`.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(domain) when is_binary(domain) do
    normalized =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing(".")

    if Regex.match?(@domain_format, normalized), do: {:ok, normalized}, else: :error
  end

  def normalize(_domain), do: :error

  @doc """
  A changeset for a new, unverified domain of the Organization with
  `organization_id`, with a fresh random verification token. The Organization
  is set here, never cast from params.
  """
  @spec create_changeset(integer(), map()) :: Ecto.Changeset.t()
  def create_changeset(organization_id, attrs) do
    %__MODULE__{organization_id: organization_id}
    |> cast(attrs, [:domain])
    |> validate_required([:domain])
    |> normalize_domain()
    |> put_change(:verification_token, new_token())
    |> unique_constraint(:domain,
      name: :organization_domains_organization_id_domain_index,
      message: gettext("is already added to your Organization")
    )
    |> check_constraint(:domain, name: :domain_lowercase)
  end

  @doc """
  Marks the domain verified at `now`, which is also a check that found the
  record. A domain another Organization verified first fails on the partial
  unique index.
  """
  @spec verify_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def verify_changeset(%__MODULE__{} = domain, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    domain
    |> change(verified_at: now, last_checked_at: now, failed_checks: 0, failing_since: nil)
    |> unique_constraint(:domain, name: :organization_domains_verified_domain_index)
  end

  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil ->
        changeset

      domain ->
        case normalize(domain) do
          {:ok, normalized} -> put_change(changeset, :domain, normalized)
          :error -> add_error(changeset, :domain, gettext("must be a domain such as example.com"))
        end
    end
  end

  defp new_token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
