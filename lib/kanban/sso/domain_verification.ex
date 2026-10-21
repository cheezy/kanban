defmodule Kanban.SSO.DomainVerification do
  @moduledoc """
  Proves that an Organization controls an email domain through a DNS TXT
  record.

  The org-admin publishes a TXT record named `record_name/1`
  (`_stride-verification.<domain>`) with the value `record_value/1`
  (`stride-verification=<token>`). A dedicated label keeps the record away
  from the crowded apex (SPF and other vendors' records) and lets a DNS admin
  delegate just that name. `check/2` passes when any TXT record at that name
  equals the expected value.

  The lookup goes through a `Kanban.SSO.TxtResolver` module: the
  `:resolver` option, else
  `config :kanban, Kanban.SSO.DomainVerification, resolver: Module`, else
  `Kanban.SSO.TxtResolver` itself (the system resolver).
  """

  alias Kanban.SSO.OrganizationDomain

  @record_prefix "_stride-verification."
  @value_prefix "stride-verification="

  @doc "The DNS name the TXT record must be published at."
  @spec record_name(OrganizationDomain.t() | String.t()) :: String.t()
  def record_name(%OrganizationDomain{domain: domain}), do: record_name(domain)
  def record_name(domain) when is_binary(domain), do: @record_prefix <> domain

  @doc "The value the TXT record must hold."
  @spec record_value(OrganizationDomain.t()) :: String.t()
  def record_value(%OrganizationDomain{verification_token: token}), do: @value_prefix <> token

  @doc """
  Returns `:ok` when a TXT record at `record_name/1` equals `record_value/1`,
  else `{:error, :record_not_found}`. A resolver error counts as not found.
  """
  @spec check(OrganizationDomain.t(), keyword()) :: :ok | {:error, :record_not_found}
  def check(%OrganizationDomain{} = domain, opts \\ []) do
    resolver = resolver(opts)

    domain
    |> record_name()
    |> resolver.lookup_txt()
    |> match_record(record_value(domain))
  end

  defp match_record({:ok, records}, expected) when is_list(records) do
    if Enum.any?(records, &(is_binary(&1) and String.trim(&1) == expected)),
      do: :ok,
      else: {:error, :record_not_found}
  end

  defp match_record(_error, _expected), do: {:error, :record_not_found}

  @doc """
  An email address as single sign-on and SCIM look accounts up and create
  them: trimmed, lowercased and without trailing dots, the dots
  `email_domain/1` ignores, so the address whose domain passed the gate is
  the one an account is found or created with.
  """
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase() |> String.trim_trailing(".")

  @doc """
  The normalized domain of an email address: the part after the last `@`.
  Returns `:error` for anything that is not an address on a valid domain.
  """
  @spec email_domain(term()) :: {:ok, String.t()} | :error
  def email_domain(email) when is_binary(email) do
    case email |> String.trim() |> String.split("@") do
      [_single] -> :error
      parts -> parts |> List.last() |> local_part_present(parts)
    end
  end

  def email_domain(_email), do: :error

  defp local_part_present(domain, parts) do
    if parts |> Enum.drop(-1) |> Enum.join("@") == "",
      do: :error,
      else: OrganizationDomain.normalize(domain)
  end

  defp resolver(opts) do
    Keyword.get_lazy(opts, :resolver, fn ->
      :kanban
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:resolver, Kanban.SSO.TxtResolver)
    end)
  end
end
