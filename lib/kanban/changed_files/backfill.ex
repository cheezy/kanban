defmodule Kanban.ChangedFiles.Backfill do
  @moduledoc """
  Pure, side-effect-free helpers for re-building a review task's
  `changed_files` payload when its diff never arrived (goal G321, task W1660).

  This module owns the *shaping* of a backfill: deciding whether a task needs
  one, turning a set of per-file diffs into the `[%{"path", "diff"}]` array
  documented in `docs/diff-contract.md` (500-line truncation, binary
  placeholder), and wrapping that array in the transport envelope the
  `PUT /api/tasks/:id/changed_files` endpoint accepts.

  It deliberately performs **no** git or HTTP I/O — those side effects live in
  `Mix.Tasks.Kanban.BackfillChangedFiles`, which injects a `diff_fun` here so
  the truncation/placeholder/encoding logic stays unit-testable. It also does
  **not** validate paths: the produced envelope is re-PUT through the real
  endpoint, which runs `Kanban.Tasks.PathSafety`/`CompletionValidation`
  unchanged — there is no second validation path.
  """

  # Exact strings from docs/diff-contract.md — the review UI and every plugin
  # key off these verbatim; do not vary them.
  @truncation_marker "[diff truncated at 500 lines]"
  @binary_placeholder "[binary file — no diff captured]"

  # Matches Kanban.Tasks.CompletionValidation @max_diff_lines — the server
  # rejects any per-file diff over this cap, so we truncate to fit.
  @max_diff_lines 500

  @typedoc """
  Result of asking for one file's diff. `{:ok, diff}` carries unified-patch
  text, `:binary` marks a binary file, and `:error` means the diff could not
  be captured (base ref gone, delete, etc.) — an entry with no `diff`.
  """
  @type diff_result :: {:ok, String.t()} | :binary | :error

  @doc "The exact truncation marker string from the diff contract."
  @spec truncation_marker() :: String.t()
  def truncation_marker, do: @truncation_marker

  @doc "The exact binary-file placeholder string from the diff contract."
  @spec binary_placeholder() :: String.t()
  def binary_placeholder, do: @binary_placeholder

  @doc """
  Whether a task's current `changed_files` value warrants a backfill.

  Only an empty value (`nil` or `[]`) needs one — a task that already carries a
  populated `changed_files` must never be overwritten (the endpoint has no such
  guard, so the caller enforces it via this predicate).
  """
  @spec needs_backfill?(term()) :: boolean()
  def needs_backfill?(nil), do: true
  def needs_backfill?([]), do: true
  def needs_backfill?(list) when is_list(list), do: false
  def needs_backfill?(_), do: false

  @doc """
  Builds the `changed_files` entry list for `paths`, asking `diff_fun` for each
  path's diff.

  Every path yields exactly one entry. A `{:ok, diff}` result stores the diff
  truncated to the 500-line cap; `:binary` stores the binary placeholder; an
  `:error` (or empty diff) stores a path-only entry (no `"diff"` key), which
  the UI renders as "no diff available" rather than dropping the file.
  """
  @spec build_entries([String.t()], (String.t() -> diff_result())) :: [map()]
  def build_entries(paths, diff_fun) when is_list(paths) and is_function(diff_fun, 1) do
    Enum.map(paths, &build_entry(&1, diff_fun.(&1)))
  end

  defp build_entry(path, :binary), do: %{"path" => path, "diff" => @binary_placeholder}
  defp build_entry(path, :error), do: %{"path" => path}

  defp build_entry(path, {:ok, diff}) when is_binary(diff) do
    case String.trim(diff) do
      "" -> %{"path" => path}
      _ -> %{"path" => path, "diff" => truncate_diff(diff)}
    end
  end

  @doc """
  Truncates a unified-patch string to the 500-line cap, appending the exact
  truncation marker on its own final line when it overflows.

  The result is at most #{@max_diff_lines} lines (499 kept lines + the marker),
  so it passes the server's per-file line-count backstop.
  """
  @spec truncate_diff(String.t()) :: String.t()
  def truncate_diff(diff) when is_binary(diff) do
    lines = diff |> String.trim_trailing("\n") |> String.split("\n")

    if length(lines) > @max_diff_lines do
      (Enum.take(lines, @max_diff_lines - 1) ++ [@truncation_marker])
      |> Enum.join("\n")
    else
      diff
    end
  end

  @doc """
  Wraps a `changed_files` entry list in the base64 transport envelope the
  upload endpoint accepts: `%{"encoding" => "base64", "data" => <b64 JSON>}`.

  Encoding the JSON array keeps ordinary source text out of the request body so
  an edge/WAF filter cannot drop it (the D61 failure the envelope exists for).
  The decoded array is validated and stored identically to a raw array.
  """
  @spec encode_envelope([map()]) :: map()
  def encode_envelope(entries) when is_list(entries) do
    %{"encoding" => "base64", "data" => entries |> Jason.encode!() |> Base.encode64()}
  end
end
