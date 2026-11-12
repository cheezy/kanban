defmodule Kanban.AuditStream.Reachability do
  @moduledoc """
  The `Kanban.Webhooks.UrlGuard` checks a destination's URL gets when it is
  saved (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §12). A refused URL is an
  error on `:url`. The host is looked up through the resolver configured
  under `config :kanban, Kanban.AuditStream, resolver: {module, function}`,
  which explicit `:resolver` options override.

  An update looks the new URL up with `lookup/2` before its transaction and
  applies the result with `put_result/2` inside it, so the destination's row
  is never locked during a DNS lookup.
  """

  alias Ecto.Changeset
  alias Kanban.Webhooks.UrlGuard

  @doc """
  Checks a changed URL on a valid changeset and adds an error on `:url` when
  `UrlGuard` refuses it. An invalid changeset, or one with no URL change, is
  returned as it is.
  """
  @spec check(Changeset.t(), keyword()) :: Changeset.t()
  def check(%Changeset{valid?: true} = changeset, opts) do
    case Changeset.get_change(changeset, :url) do
      nil -> changeset
      url -> add_error(changeset, UrlGuard.check(url, guard_opts(opts)))
    end
  end

  def check(changeset, _opts), do: changeset

  @doc """
  Looks up the URL given in `attrs` (an atom or string `url` key) and returns
  `UrlGuard.check/2`'s result, or `nil` when `attrs` gives no URL.
  """
  @spec lookup(map(), keyword()) :: {:ok, term()} | {:error, term()} | nil
  def lookup(attrs, opts) do
    case Map.get(attrs, :url, Map.get(attrs, "url")) do
      url when is_binary(url) -> UrlGuard.check(url, guard_opts(opts))
      _none -> nil
    end
  end

  @doc """
  Applies a `lookup/2` result to a valid changeset that changes the URL. A
  result for a URL the changeset does not change (the stored one, given
  again) is ignored.
  """
  @spec put_result(Changeset.t(), {:ok, term()} | {:error, term()} | nil) :: Changeset.t()
  def put_result(%Changeset{valid?: true} = changeset, {_, _} = result) do
    case Changeset.get_change(changeset, :url) do
      nil -> changeset
      _url -> add_error(changeset, result)
    end
  end

  def put_result(changeset, _result), do: changeset

  @doc """
  `UrlGuard.check/2` for a stored URL about to be sent to, over the configured
  resolver (explicit `opts` win), so DNS is checked again at send time
  (§12.1).
  """
  @spec check_url(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def check_url(url, opts \\ []) when is_binary(url), do: UrlGuard.check(url, guard_opts(opts))

  defp add_error(changeset, {:ok, _resolved}), do: changeset

  defp add_error(changeset, {:error, reason}),
    do: Changeset.add_error(changeset, :url, UrlGuard.error_message(reason), reason: reason)

  # Explicit opts win over the configured resolver.
  defp guard_opts(opts), do: Keyword.merge(configured_guard_opts(), opts)

  defp configured_guard_opts do
    case Application.get_env(:kanban, Kanban.AuditStream, [])[:resolver] do
      {module, function} -> [resolver: &apply(module, function, [&1])]
      nil -> []
    end
  end
end
