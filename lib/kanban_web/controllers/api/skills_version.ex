defmodule KanbanWeb.API.SkillsVersion do
  @moduledoc """
  Decides whether an agent's reported `skills_version` is stale against this
  server's own constant.

  Extracted from `KanbanWeb.API.TaskJSON` by D267, where the comparison was
  exact string equality: anything not byte-equal to the server constant drew
  the `skills_update_required` directive. That made the directive fire on
  versions that are *newer* than the server's and on ones that merely carry a
  quoting artifact, and in both cases the prescribed action — `/plugin update`
  — cannot make the value byte-equal, so the directive was unsatisfiable and
  automation gating on its absence stalled.

  ## The rule: only STRICTLY OLDER is stale

  `stale?/2` returns `true` only when the reported version is strictly older
  than the server's. Equal, newer, and *unorderable* all read as current.

  That asymmetry is deliberate and is the constraint the fix turns on:
  `skills_version` is **not a totally-ordered version space across runtimes**.
  Some ports pin a constant such as `"1.0"` and never increment it, so a
  comparison that treated "different" or "unparsable" as stale would mark a
  correctly-pinned port stale forever, which is the same unsatisfiable
  directive in a new costume.

  ## Unparsable versions draw no directive, and that is a decision

  A value like `"abc"` cannot be ordered against `"1.0"`, so it is not
  *strictly older* — it is unknown. Two reasons it gets no directive rather
  than one with softer wording:

    * The only directive this API has says "Your local skills are outdated"
      and prescribes `/plugin update`. Both are claims we cannot support about
      a version we cannot order, and the update cannot resolve it either — the
      exact unsatisfiability D267 exists to remove.
    * The governing rule above admits exactly one reason to fire: strictly
      older. Widening it to "anything we failed to parse" reintroduces the
      false-positive class through the back door.

  A caller sending garbage still gets `current_skills_version` in the
  response and can compare for itself.

  ## Comparison is component-wise and numeric

  Versions are compared as dot-separated integer components, not as strings:
  a string compare puts `"1.10"` *below* `"1.9"`, which would report a newer
  agent as stale. Missing trailing components are treated as zero, so `"1"`,
  `"1.0"` and `"1.0.0"` are the same version.

  A SemVer-style pre-release or build suffix is trimmed before parsing, so
  `"0.0.1-stale"` orders on `0.0.1` and is correctly older than `"1.0"`.
  Discarding such a value as unorderable would throw away leading components
  that order it perfectly well. One consequence is deliberate: a pre-release
  compares EQUAL to its release, so `"1.0.0-alpha"` against a server on
  `"1.0.0"` draws no directive. That is the conservative direction — the rule
  below admits only *strictly older*, and an agent one pre-release step from
  current has nothing useful to be told.

  Elixir's `Version` module is deliberately not used: it requires strict
  SemVer, and `Version.parse("1.0")` returns `:error` — the server's own
  constant would not parse.

  ## Where the directive is and is not delivered — two decisions, recorded

  D267 was handed two design edges to settle rather than to fix. Both were
  **examined and deliberately left as they are**; they are written down here
  so the next reader can tell an accepted edge from an overlooked one.

  **The `next` 404 empty-queue branch carries no skills keys, and that is
  accepted.** `TaskController.next/2` answers an empty Ready column with a bare
  `{"error": ...}` that never reaches `TaskJSON`, so an agent polling an empty
  queue is never told its skills are stale. That is acceptable because the
  directive is advisory about work the agent is *about to do*: with no task to
  claim there is nothing for it to gate, and the moment work appears the poll
  returns 200 and the directive arrives — before the agent claims anything.
  The signal is deferred to the point where it is actionable, not lost. Adding
  it to the 404 would also change that response's shape for every caller,
  which the task's own pitfall about not changing the directive's shape argues
  against.

  **The `fields=` projection stays outside this channel, re-affirmed.** The
  projection is documented in `TaskJSON` as "deliberately data-only (it is the
  surgical read)", and its clause never calls `maybe_add_skills_version/2`. A
  caller asking for exactly the fields it names should not receive two it did
  not, or the projection stops being a projection. Nothing is lost: an agent
  running the lifecycle passes through `next`, `claim` and `complete`, every
  one of which threads this comparison, so a projection-only reader is a
  targeted read rather than an agent that could miss its only warning.
  """

  @doc """
  Returns `true` only when `reported` is strictly older than `server`.

  Every other outcome — equal, newer, blank, absent, or unorderable — returns
  `false`, meaning no staleness directive is owed.

  Both arguments are trimmed before comparison, so a value carrying a quoting
  or shell artifact such as `"1.0 "` is judged on its content.

  ## Examples

      iex> alias KanbanWeb.API.SkillsVersion
      iex> SkillsVersion.stale?("0.1", "1.0")
      true
      iex> SkillsVersion.stale?("1.0", "1.0")
      false
      iex> SkillsVersion.stale?("2.0", "1.0")
      false
      iex> SkillsVersion.stale?("1.0 ", "1.0")
      false
      iex> SkillsVersion.stale?("1.9", "1.10")
      true
      iex> SkillsVersion.stale?("abc", "1.0")
      false
      iex> SkillsVersion.stale?("0.0.1-stale", "1.0")
      true
      iex> SkillsVersion.stale?("1.0.0-alpha", "1.0.0")
      false
      iex> SkillsVersion.stale?(nil, "1.0")
      false
      iex> SkillsVersion.stale?("", "1.0")
      false
  """
  @spec stale?(String.t() | nil, String.t()) :: boolean()
  def stale?(reported, server)

  def stale?(reported, server) when is_binary(reported) and is_binary(server) do
    trimmed = String.trim(reported)

    # An exact match short-circuits before any parsing, so a port pinning a
    # constant the parser would reject still reads as current.
    cond do
      trimmed == "" -> false
      trimmed == String.trim(server) -> false
      true -> strictly_older?(trimmed, String.trim(server))
    end
  end

  def stale?(_reported, _server), do: false

  defp strictly_older?(reported, server) do
    with {:ok, reported_parts} <- components(reported),
         {:ok, server_parts} <- components(server) do
      compare(reported_parts, server_parts) == :lt
    else
      # Unorderable on either side: not strictly older, so not stale.
      :error -> false
    end
  end

  defp components(version) do
    parts =
      version
      |> strip_suffix()
      |> String.split(".")

    if Enum.all?(parts, &numeric?/1) do
      {:ok, Enum.map(parts, &String.to_integer/1)}
    else
      :error
    end
  end

  # \A and \z rather than ^ and $: the latter also match around a trailing
  # newline, so a component of "1\n" would pass and then raise in
  # String.to_integer/1.
  defp numeric?(part), do: String.match?(part, ~r/\A\d+\z/)

  defp compare(reported_parts, server_parts) do
    width = max(length(reported_parts), length(server_parts))
    padded_reported = pad(reported_parts, width)
    padded_server = pad(server_parts, width)

    cond do
      padded_reported < padded_server -> :lt
      padded_reported > padded_server -> :gt
      true -> :eq
    end
  end

  defp pad(parts, width), do: parts ++ List.duplicate(0, width - length(parts))

  # Drop a SemVer-style pre-release or build suffix before parsing. Without
  # this, "0.0.1-stale" is unorderable and therefore not stale -- discarding
  # a leading 0 that orders it against a server on 1.0 perfectly well.
  defp strip_suffix(version) do
    version
    |> String.split(["-", "+"], parts: 2)
    |> List.first()
  end
end
