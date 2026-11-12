defmodule Kanban.AuditStream.StartPoint do
  @moduledoc """
  Where a new destination's first batch begins
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.5): the `start_from` a create
  takes, which values each kind offers, and the cursor each one gives.

  Datadog refuses events older than 18 hours, so it offers `"17h"` instead of
  the longer windows.
  """

  alias Ecto.Changeset

  @options %{
    splunk_hec: ~w(now 24h 7d all),
    datadog: ~w(now 17h),
    https: ~w(now 24h 7d all)
  }

  @window_seconds %{"24h" => 86_400, "7d" => 604_800, "17h" => 61_200}

  @doc "The start points `kind` offers."
  @spec options(atom()) :: [String.t()]
  def options(kind), do: Map.get(@options, kind, [])

  @doc """
  Takes `start_from` (a string or atom key) out of `attrs`, returning it as a
  string, `"now"` when absent, with the remaining attributes.
  """
  @spec pop(map() | keyword()) :: {term(), map()}
  def pop(attrs) do
    attrs = Map.new(attrs)
    {atom_value, attrs} = Map.pop(attrs, :start_from)
    {string_value, attrs} = Map.pop(attrs, "start_from")
    {normalize(string_value || atom_value), attrs}
  end

  @doc """
  Adds an error on `:start_from` unless the changeset's kind offers
  `start_from`. A changeset with no kind is left to its own errors.
  """
  @spec validate(Changeset.t(), term()) :: Changeset.t()
  def validate(changeset, start_from) do
    case Changeset.get_field(changeset, :kind) do
      nil -> changeset
      kind -> check(changeset, start_from in options(kind))
    end
  end

  @doc """
  The cursor attributes for `start_from`, given the horizon read inside the
  creating transaction: `"now"` is (`horizon`, 0); a time window is (0, 0)
  with `not_before` at the window's start, never a position just before the
  oldest matching event; `"all"` is (0, 0) with no `not_before`.
  """
  @spec cursor_attrs(String.t(), non_neg_integer()) :: map()
  def cursor_attrs("now", horizon), do: %{last_txid: horizon, last_event_id: 0}
  def cursor_attrs("all", _horizon), do: %{last_txid: 0, last_event_id: 0}

  def cursor_attrs(window, _horizon) do
    seconds = Map.fetch!(@window_seconds, window)
    not_before = DateTime.add(DateTime.utc_now(), -seconds, :second)
    %{last_txid: 0, last_event_id: 0, not_before: not_before}
  end

  defp normalize(nil), do: "now"
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp check(changeset, true), do: changeset

  defp check(changeset, false),
    do: Changeset.add_error(changeset, :start_from, "is invalid", validation: :inclusion)
end
