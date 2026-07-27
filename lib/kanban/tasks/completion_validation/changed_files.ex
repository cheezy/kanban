defmodule Kanban.Tasks.CompletionValidation.ChangedFiles do
  @moduledoc """
  Validates the optional `changed_files` array on a completion payload.

  One responsibility: given the raw array, decide whether every entry is a
  well-formed `%{"path" => ..., "diff" => ...}` map, and report every failing
  entry rather than the first. It shares nothing with reviewer validation —
  no enums, no section verdicts, no gettext — which is why it separates
  cleanly from the rest of the family.

  ## Path safety (D114)

  The `path` of every entry is fully attacker-controlled: it arrives on the
  public `PUT /api/tasks/:id/changed_files` endpoint. Every path is therefore
  run through `Kanban.Tasks.PathSafety`, which rejects absolute paths, `..`
  traversal, and embedded null bytes, so a stored path cannot escape the repo
  root. That call is the reason this module exists as a boundary rather than a
  convenience: dropping it would let a traversal-shaped path reach persistence.

  Rejection messages name only the entry index and static text — they never
  echo the submitted path back to the caller.
  """

  alias Kanban.Tasks.PathSafety

  @max_diff_lines 500

  @doc """
  Validates the optional `changed_files` array on the completion payload.

  Returns `{:ok, value}` when valid (including `nil` for legacy payloads
  that omit the field entirely and `[]` for empty arrays), or
  `{:error, [{field, message}, ...]}` listing every failing entry.

  Each entry must be a map with a non-empty string `"path"`. The `"diff"`
  field is optional; when present it must be a string of at most
  #{@max_diff_lines} lines. The line cap is a defensive backstop — plugins
  are expected to truncate before sending, per `docs/diff-contract.md`.
  """
  def validate(nil),
    do: {:error, [{:changed_files, "must be present (send [] to clear)"}]}

  def validate(value) when is_list(value) do
    errors =
      value
      |> Enum.with_index()
      |> Enum.reduce([], fn {entry, idx}, acc -> check_changed_file_entry(acc, entry, idx) end)

    case errors do
      [] -> {:ok, value}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_value), do: {:error, [{:changed_files, "must be a list"}]}

  # Per-entry validator for `changed_files`. Uses the same static-atom +
  # index-in-message pattern as `check_issue_entry/3` so we do not create
  # runtime atoms per array index.
  defp check_changed_file_entry(errors, entry, idx) when is_map(entry) do
    errors
    |> check_changed_file_path(entry, idx)
    |> check_changed_file_diff(entry, idx)
  end

  defp check_changed_file_entry(errors, _entry, idx),
    do: [{:changed_file_entry, "changed_files[#{idx}] must be a map"} | errors]

  # D114: the changed_files path is fully attacker-controlled (public
  # PUT /api/tasks/:id/changed_files). Reject absolute paths, `..` traversal, and
  # null bytes so a stored path cannot escape the repo root — parity with the
  # key_files embed, via the shared Kanban.Tasks.PathSafety predicate.
  defp check_changed_file_path(errors, entry, idx) do
    case entry |> Map.get("path") |> PathSafety.validate() do
      :ok ->
        errors

      {:error, reason} ->
        [{:changed_file_path, changed_file_path_error(idx, reason)} | errors]
    end
  end

  defp changed_file_path_error(idx, reason) when reason in [:empty, :not_a_string],
    do: "changed_files[#{idx}] must have a non-empty string \"path\""

  defp changed_file_path_error(idx, :absolute),
    do: "changed_files[#{idx}] \"path\" must be a relative path, not absolute"

  defp changed_file_path_error(idx, :traversal),
    do: "changed_files[#{idx}] \"path\" must not contain .. path traversal"

  defp changed_file_path_error(idx, :null_byte),
    do: "changed_files[#{idx}] \"path\" must not contain a null byte"

  defp check_changed_file_diff(errors, entry, idx) do
    case Map.get(entry, "diff") do
      nil ->
        errors

      diff when is_binary(diff) ->
        if diff_line_count(diff) > @max_diff_lines do
          [
            {:changed_file_diff,
             "changed_files[#{idx}].diff exceeds the #{@max_diff_lines}-line cap"}
            | errors
          ]
        else
          errors
        end

      _ ->
        [{:changed_file_diff, "changed_files[#{idx}].diff must be a string"} | errors]
    end
  end

  # Counts logical lines in a diff. A trailing newline is treated as a
  # line terminator, not a separator — so a 500-line patch with or
  # without a trailing newline reports 500 lines.
  defp diff_line_count(diff) do
    diff
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> length()
  end
end
