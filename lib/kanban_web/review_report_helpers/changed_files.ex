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

  ## Why `KanbanWeb.ReviewLive` still has its own copies

  `ReviewLive` keeps private near-duplicates of both functions. W1965 marks
  `review_live.ex` read-only, so collapsing the Review queue onto this module
  would have put an unreviewed edit into the one file whose behaviour the task
  most needed to leave alone. That collapse is **tracked as W2007**, not an
  oversight — fix path parsing or entry matching here and the copies in
  `review_live.ex` need the same fix until W2007 lands.

  Note the Review queue's list also unions the legacy comma-separated
  `actual_files_changed` string, which this module intentionally does NOT — see
  `changed_file_paths/1`. That union, and the payload merge that supports it,
  stay in `ReviewLive` even after W2007.

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
