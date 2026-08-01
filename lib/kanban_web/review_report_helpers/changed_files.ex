defmodule KanbanWeb.ReviewReportHelpers.ChangedFiles do
  @moduledoc """
  Read accessors over a task's `changed_files` JSONB array.

  A sibling of `KanbanWeb.ReviewReportHelpers` rather than part of it: that
  module is already past the size guidance in `AGENTS.md`, and this is the
  same "split a focused concern into its own module" shape W2003 used for
  `KanbanWeb.ReviewReportHelpers.Explorer` (W1965).

  Entries are string-keyed maps carrying `"path"`, an optional `"diff"` and an
  optional `"diff_url"` — the per-file shape defined in `docs/diff-contract.md`,
  which `KanbanWeb.ReviewDiffPanel` consumes directly. `lookup_changed_file/2`
  therefore returns the stored entry unchanged rather than building a payload:
  the entry already IS the panel's `selected_file` shape.

  ## Both hosts share this module

  The task view and `KanbanWeb.ReviewLive` both call these two accessors, so a
  fix to path parsing or entry matching here reaches both. W1965 had marked
  `review_live.ex` read-only and left it carrying private near-duplicates;
  W2007 deleted those and routed the Review queue through this module.

  Two Review-queue behaviours deliberately did NOT move here, and should not:

    * Its file list unions the legacy comma-separated `actual_files_changed`
      string, which `changed_file_paths/1` intentionally omits — see that
      function's `@doc` for why.
    * Because of that union it merges a `%{"path" => path, "diff" => nil}`
      fallback over an unresolved lookup, so a legacy-only path still renders a
      row. That merge lives in `ReviewLive.selected_file_payload/2`. Keeping it
      out of here is what lets `lookup_changed_file/2` return `nil` and fail
      closed for the task view.

  Every function is pure: no DB access, no scope resolution. These must not
  become an authorization decision point.
  """

  @doc """
  Every non-blank `"path"` in the task's `changed_files`, in stored order.

  Tolerates both string- and atom-keyed entries, matching the key-tolerance
  convention the sibling modules follow, and drops entries whose path is
  missing, blank, or not a binary. Returns `[]` when `changed_files` is `nil`,
  absent, or not a list.

  Deliberately does NOT union the legacy `actual_files_changed` string the way
  the Review queue does. A legacy-only path has no `changed_files` entry to
  resolve, so listing it would render a row that selects nothing when clicked —
  every path this returns is one `lookup_changed_file/2` can resolve. Pure; no
  DB access.
  """
  @spec changed_file_paths(map()) :: [String.t()]
  def changed_file_paths(%{changed_files: list}) when is_list(list),
    do: Enum.flat_map(list, &entry_path/1)

  def changed_file_paths(%{"changed_files" => list}) when is_list(list),
    do: Enum.flat_map(list, &entry_path/1)

  def changed_file_paths(_task), do: []

  defp entry_path(%{"path" => path}) when is_binary(path) and path != "", do: [path]
  defp entry_path(%{path: path}) when is_binary(path) and path != "", do: [path]
  defp entry_path(_entry), do: []

  @doc """
  The task's own `changed_files` entry for `path`, or `nil` when there is none.

  This is the ONLY resolution path for a caller-supplied file path: the click
  event carries whatever path the client sent, and it is resolved here against
  this task's stored list and nothing else. It never touches the filesystem and
  never consults another task.

  Returns `nil` rather than a synthesized `%{"path" => path}` payload for an
  unknown path, so an unmatched click fails closed — the caller assigns `nil`,
  no row renders active, and no diff renders at all. Do not "helpfully" echo
  the requested path back into a payload here. Pure; no DB access.
  """
  @spec lookup_changed_file(map(), String.t()) :: map() | nil
  def lookup_changed_file(%{changed_files: list}, path) when is_list(list) and is_binary(path),
    do: find_entry(list, path)

  def lookup_changed_file(%{"changed_files" => list}, path)
      when is_list(list) and is_binary(path),
      do: find_entry(list, path)

  def lookup_changed_file(_task, _path), do: nil

  defp find_entry(list, path) do
    Enum.find(list, fn entry -> is_map(entry) and entry_matches?(entry, path) end)
  end

  defp entry_matches?(%{"path" => path}, path), do: true
  defp entry_matches?(%{path: path}, path), do: true
  defp entry_matches?(_entry, _path), do: false
end
