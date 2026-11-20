defmodule Kanban.Reviews.MobileReviewFile do
  @moduledoc """
  One file of a pending review, for the app's flagged-file screen
  (`GET /api/me/reviews/:task_id/files/:index`, W2753;
  `docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §6.5, §7.5). It is
  reached through `Kanban.Reviews.MobileReview.file/3`, and kept apart from
  `Kanban.Reviews.MobileReview` so that module stays one screen's builder.

  `index` is the file's position in the task's `changed_files`, the `index`
  the review detail lists. An index past the end, an entry that is not a map
  or has no usable path, and a task with no `changed_files` (its files come
  from `actual_files_changed` and have no index) are all
  `{:error, :not_found}`, so an index only ever reaches this task's own
  stored diffs.

  The file returned carries:

    * `index`, `path` (normalized as `MobileReview.normalize_file/1` does),
      `language` (`Kanban.Reviews.DiffHighlighter.language/1`) and
      `file_count`, the number of files the review detail lists, for the
      screen's "1 of 6";
    * `additions`, `deletions` and `truncated`, from
      `Kanban.Reviews.MobileGuard.diff_stats/1`. A path listed twice is one
      file, as in the detail: its counts are summed, and `lines` holds each
      of its diffs in stored order, so the detail's index reaches all of
      them and a note on a line of the later diff is anchored;
    * `flagged` and `flag_reason`, exactly as the detail's file row has them;
    * `lines`, what `highlight` returns for each of the path's diffs (`[]`
      for an empty or missing one), at most 500 per diff;
    * `notes`: every `reviewer_result` issue whose `file` names this path
      (`MobileReview.issue_path/2`: an issue names one listed path, never a
      shorter path it merely ends in), in the order the reviewer gave them. A note's `line` is the issue's
      line when it is a positive integer, else `nil`, and `anchored` says
      whether a diff line with that new-side number is in `lines`; a note
      that is not anchored belongs to the file as a whole, as does one
      whose line is beyond the diff;
    * `review_requested_at`, and `files_version` (`files_version/1`), the
      version of the file list the index points into. A resubmit, or an
      agent replacing `changed_files` in place (which leaves
      `review_requested_at` as it was), can make the same index name another
      file. Each change to the list changes `files_version`, so the app sends
      the detail's `files_version` with the index (`build/4`) and is answered
      `{:error, {:files_changed, current}}` instead of another file's diff.

  Pure apart from `highlight`, which is passed in: the context passes
  `Kanban.Reviews.DiffHighlighter.highlight/4`, whose cache is keyed on the
  diff's hash and the path, so a changed diff or a renamed file is never
  served from an old entry.
  Issue fields are agent-supplied, so nothing here raises on an unexpected
  shape.
  """

  alias Kanban.Reviews.DiffHighlighter
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task

  @type highlight ::
          (term(), non_neg_integer(), String.t() | nil, String.t() -> [DiffHighlighter.line()])

  @type note :: %{
          line: pos_integer() | nil,
          anchored: boolean(),
          severity: String.t() | nil,
          category: String.t() | nil,
          description: String.t() | nil
        }

  @type t :: %{
          index: non_neg_integer(),
          path: String.t(),
          language: atom(),
          file_count: non_neg_integer(),
          additions: non_neg_integer() | nil,
          deletions: non_neg_integer() | nil,
          truncated: boolean(),
          flagged: boolean(),
          flag_reason: :issue | :security | nil,
          lines: [DiffHighlighter.line()],
          notes: [note()],
          review_requested_at: DateTime.t() | nil,
          files_version: String.t()
        }

  @doc """
  The file at `index` of `task`'s `changed_files`, as the moduledoc
  describes, or `{:error, :not_found}`.

  `expected_version` is the `files_version/1` the caller read the index
  from, or `nil` to skip the check. When it is given and the list has changed
  since, the answer is `{:error, {:files_changed, current_version}}`, whatever
  the index, because the index no longer says which file was meant.
  """
  @spec build(Task.t(), non_neg_integer(), highlight(), String.t() | nil) ::
          {:ok, t()} | {:error, :not_found | {:files_changed, String.t()}}
  def build(task, index, highlight, expected_version \\ nil)

  def build(%Task{} = task, index, highlight, expected_version)
      when is_binary(expected_version) do
    case files_version(task) do
      ^expected_version -> build(task, index, highlight, nil)
      current -> {:error, {:files_changed, current}}
    end
  end

  def build(%Task{changed_files: [_ | _] = entries} = task, index, highlight, nil)
      when is_integer(index) and index >= 0 and is_function(highlight, 4) do
    with %{} = entry <- Enum.at(entries, index),
         path when is_binary(path) <- entry_path(entry) do
      {:ok, file(task, index, entry, path, highlight)}
    else
      _ -> {:error, :not_found}
    end
  end

  def build(%Task{}, _index, _highlight, nil), do: {:error, :not_found}

  @doc """
  The version of `task`'s file list: a short opaque string that changes
  whenever the list the detail's `index` points into changes. It is taken
  over every stored `changed_files` entry, in order: its path exactly as
  stored and a hash of its diff, so a reorder, a rename, an added or removed
  entry and a changed diff all give a new version. A task with no stored
  diffs is versioned by its `actual_files_changed`. The same task always
  gives the same version.
  """
  @spec files_version(Task.t()) :: String.t()
  def files_version(%Task{} = task) do
    material =
      case task.changed_files do
        [_ | _] = entries -> {:changed_files, Enum.map(entries, &version_entry/1)}
        _none -> {:actual_files_changed, task.actual_files_changed}
      end

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(material))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  defp version_entry(entry) when is_map(entry) do
    path = entry_value(entry, :path)

    diff =
      case entry_diff(entry) do
        nil -> nil
        text -> :crypto.hash(:sha256, text)
      end

    {if(is_binary(path), do: path), diff}
  end

  defp version_entry(_entry), do: :not_a_map

  defp file(task, index, entry, path, highlight) do
    entries = same_path_entries(task.changed_files, index, entry, path)
    rows = MobileReview.files(task)
    lines = highlight_entries(entries, task.id, path, highlight)

    task
    |> header(index, path, rows)
    |> Map.merge(%{lines: lines, notes: notes(task, path, lines, Enum.map(rows, & &1.path))})
    |> Map.merge(entry_stats(entries))
  end

  # The fields that come from the detail's file row and the task.
  defp header(task, index, path, rows) do
    row = Enum.find(rows, &(&1.path == path)) || %{flagged: false, flag_reason: nil}

    %{
      index: index,
      path: path,
      language: DiffHighlighter.language(path),
      file_count: length(rows),
      flagged: row.flagged,
      flag_reason: row.flag_reason,
      review_requested_at: task.review_requested_at,
      files_version: files_version(task)
    }
  end

  defp highlight_entries(entries, task_id, path, highlight) do
    Enum.flat_map(entries, fn {e, i} -> highlight.(task_id, i, entry_diff(e), path) end)
  end

  defp entry_stats(entries) do
    entries
    |> Enum.map(fn {e, _i} -> e |> entry_diff() |> stats() end)
    |> sum_stats()
  end

  # Every stored entry that normalizes to `path`, in order, so a path listed
  # twice shows all its diffs, as the detail's summed row counts them.
  defp same_path_entries(entries, index, entry, path) do
    same =
      for {e, i} <- Enum.with_index(entries),
          is_map(e),
          entry_path(e) == path,
          do: {e, i}

    if same == [], do: [{entry, index}], else: same
  end

  defp sum_stats([first | rest]) do
    Enum.reduce(rest, first, fn s, acc ->
      %{
        additions: add(acc.additions, s.additions),
        deletions: add(acc.deletions, s.deletions),
        truncated: acc.truncated or s.truncated
      }
    end)
  end

  defp add(nil, nil), do: nil
  defp add(a, b), do: (a || 0) + (b || 0)

  defp entry_path(entry), do: entry |> entry_value(:path) |> MobileReview.normalize_file()

  defp entry_value(entry, key), do: Map.get(entry, Atom.to_string(key)) || Map.get(entry, key)

  defp entry_diff(entry) do
    case entry_value(entry, :diff) do
      diff when is_binary(diff) -> diff
      _ -> nil
    end
  end

  defp stats(diff) when is_binary(diff), do: MobileGuard.diff_stats(diff)
  defp stats(nil), do: %{additions: nil, deletions: nil, truncated: false}

  # Every issue whose `file` names `path` among the listed `paths`
  # (`MobileReview.issue_path/2`), each anchored to the diff line whose
  # new-side number is its `line`, when there is one.
  defp notes(%Task{} = task, path, lines, paths) do
    new_lines = MapSet.new(lines, &Map.get(&1, :new))

    task
    |> MobileReview.issues()
    |> Enum.filter(
      &(&1["file"] |> MobileReview.normalize_file() |> MobileReview.issue_path(paths) == path)
    )
    |> Enum.map(&note(&1, new_lines))
  end

  defp note(issue, new_lines) do
    line = issue_line(issue["line"])

    %{
      line: line,
      anchored: line != nil and MapSet.member?(new_lines, line),
      severity: text(issue["severity"]),
      category: text(issue["category"]),
      description: text(issue["description"])
    }
  end

  defp issue_line(line) when is_integer(line) and line > 0, do: line
  defp issue_line(_line), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
