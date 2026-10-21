defmodule Kanban.SSO.TxtResolver do
  @moduledoc """
  Looks up DNS TXT records for domain verification
  (`Kanban.SSO.DomainVerification`).

  The default implementation, `lookup_txt/1` in this module, asks the system
  resolver through `:inet_res`. Tests configure a stub module instead
  (`config :kanban, Kanban.SSO.DomainVerification, resolver: Module`), so no
  test touches DNS.
  """

  @doc "Returns every TXT record at `name`, each with its chunks joined."
  @callback lookup_txt(name :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @timeout 5_000

  @doc "The `c:lookup_txt/1` callback, with a five-second resolver timeout."
  @spec lookup_txt(String.t()) :: {:ok, [String.t()]}
  def lookup_txt(name) when is_binary(name) do
    lookup_txt(name, timeout: @timeout)
  end

  @doc """
  Like `lookup_txt/1`, with `:inet_res` resolver options such as `:timeout`
  and `:nameservers`. An empty answer is `{:ok, []}`.
  """
  @spec lookup_txt(String.t(), keyword()) :: {:ok, [String.t()]}
  def lookup_txt(name, opts) when is_binary(name) and is_list(opts) do
    records =
      name
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :txt, opts)
      |> join_chunks()

    {:ok, records}
  end

  @doc """
  Turns `:inet_res` TXT answers, one list of character-string chunks per
  record, into one string per record. DNS splits a TXT value longer than 255
  bytes into chunks, which are joined without a separator.
  """
  @spec join_chunks([[charlist()]]) :: [String.t()]
  def join_chunks(records) when is_list(records) do
    Enum.map(records, fn chunks -> Enum.map_join(chunks, &to_string/1) end)
  end
end
