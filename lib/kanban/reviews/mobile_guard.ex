defmodule Kanban.Reviews.MobileGuard do
  @moduledoc """
  The large-change guard for reviews made on a phone
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §7.6).

  A task is a **large change** when any of these holds:

    * it changed more than `max_files/0` files, counted from `changed_files`,
      or from `actual_files_changed` when `changed_files` is empty;
    * it changed more than `max_changed_lines/0` lines, counted as added plus
      deleted lines across every stored diff;
    * any stored diff was cut at the per-diff cap (it ends with
      `Kanban.ChangedFiles.Backfill.truncation_marker/0`), because its true
      size is then unknown.

  Lines are counted only from the diffs stored in `changed_files` — never
  from `actual_files_changed`, which names files but carries no lines. A
  line counts when it starts with `+` or `-`, except a `--- `/`+++ ` file
  header pair outside a hunk, the truncation marker and the binary
  placeholder. Inside a hunk, whose length its `@@` line gives, every `+` and
  `-` line counts, so a deleted `-- x` followed by an added `++ y` is two
  changes, not a header.

  The limits are constants in Phase 1. The module is pure: it reads only the
  task it is given and never touches the database.
  """

  alias Kanban.ChangedFiles.Backfill
  alias Kanban.Tasks.Task

  @max_files 10
  @max_changed_lines 500

  @type size :: %{
          files: non_neg_integer(),
          changed_lines: non_neg_integer(),
          truncated: boolean()
        }

  @type diff_stats :: %{
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          truncated: boolean()
        }

  @typedoc "A device's class; `nil` is the web."
  @type device_class :: :phone | :tablet | nil

  @doc "The most files a phone may approve: #{@max_files}."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "The most changed lines a phone may approve: #{@max_changed_lines}."
  @spec max_changed_lines() :: pos_integer()
  def max_changed_lines, do: @max_changed_lines

  @doc """
  Both limits. `GET /api/me` shows the same two values, under its own keys,
  through `Kanban.Devices.AppPolicy.phone_limits/0`.
  """
  @spec limits() :: %{max_files: pos_integer(), max_changed_lines: pos_integer()}
  def limits, do: %{max_files: @max_files, max_changed_lines: @max_changed_lines}

  @doc """
  The size of `task`'s change: how many files it touched, how many lines its
  stored diffs add or delete, and whether any diff was cut at the cap.
  """
  @spec size(Task.t()) :: size()
  def size(%Task{} = task) do
    diffs = task |> stored_entries() |> Enum.flat_map(&diff_text/1)

    %{
      files: file_count(task),
      changed_lines: Enum.reduce(diffs, 0, &(changed_lines(&1) + &2)),
      truncated: Enum.any?(diffs, &truncated?/1)
    }
  end

  @doc """
  Whether `task` (or a size from `size/1`) is a large change: more than
  #{@max_files} files, more than #{@max_changed_lines} lines, or a diff cut at
  the cap.
  """
  @spec large_change?(Task.t() | size()) :: boolean()
  def large_change?(%Task{} = task), do: task |> size() |> large_change?()

  def large_change?(%{files: files, changed_lines: lines, truncated: truncated}) do
    files > @max_files or lines > @max_changed_lines or truncated == true
  end

  @doc """
  The size of one stored diff: the lines it adds, the lines it deletes, and
  whether it was cut at the per-diff cap. Counts exactly as `size/1` does, so
  the additions plus deletions of every diff a task stores sum to its
  `changed_lines`.
  """
  @spec diff_stats(String.t()) :: diff_stats()
  def diff_stats(diff) when is_binary(diff) do
    {additions, deletions} = count_lines(diff)
    %{additions: additions, deletions: deletions, truncated: truncated?(diff)}
  end

  @doc """
  Whether a device of `device_class` may approve `task` (or a size from
  `size/1`): `:ok`, or `{:error, :too_large_for_phone}` for a large change on
  a phone. A tablet, and the web (`nil`), may approve any change. Request
  changes is never limited.

  This is the one rule: the review detail's `approvable_here` reads it, and
  the app's approve route must refuse with the same reason.
  """
  @spec check(Task.t() | size(), device_class()) :: :ok | {:error, :too_large_for_phone}
  def check(task_or_size, :phone) do
    if large_change?(task_or_size), do: {:error, :too_large_for_phone}, else: :ok
  end

  def check(_task_or_size, _device_class), do: :ok

  defp stored_entries(%Task{changed_files: entries}) when is_list(entries), do: entries
  defp stored_entries(%Task{}), do: []

  defp file_count(%Task{} = task) do
    case stored_entries(task) do
      [] -> task.actual_files_changed |> listed_files() |> length()
      entries -> entries |> Enum.flat_map(&entry_path/1) |> Enum.uniq() |> length()
    end
  end

  defp listed_files(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp listed_files(_text), do: []

  defp entry_path(entry) when is_map(entry) do
    case Map.get(entry, "path") || Map.get(entry, :path) do
      path when is_binary(path) -> if String.trim(path) == "", do: [], else: [path]
      _ -> []
    end
  end

  defp entry_path(_entry), do: []

  defp diff_text(entry) when is_map(entry) do
    case Map.get(entry, "diff") || Map.get(entry, :diff) do
      diff when is_binary(diff) -> [diff]
      _ -> []
    end
  end

  defp diff_text(_entry), do: []

  # The hunk state is the {old, new} lines its `@@` header says are still to
  # come; {0, 0} is outside a hunk. Only there is a `--- `/`+++ ` pair a file
  # header; inside a hunk it is a deleted and an added line. A context line
  # (a leading space, or a blank line some tools write for one) uses one of
  # each.
  @outside_hunk {0, 0}

  @hunk_header ~r/\A@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/

  defp changed_lines(diff) do
    {additions, deletions} = count_lines(diff)
    additions + deletions
  end

  # The count is {added, deleted}.
  defp count_lines(diff),
    do: diff |> String.split(["\r\n", "\n"]) |> count_changes(@outside_hunk, {0, 0})

  defp count_changes([], _hunk, count), do: count

  defp count_changes(["@@" <> _ = line | rest], _hunk, count),
    do: count_changes(rest, hunk_size(line), count)

  defp count_changes(["--- " <> _, "+++ " <> _ | rest], @outside_hunk, count),
    do: count_changes(rest, @outside_hunk, count)

  defp count_changes(["+" <> _ | rest], {old, new}, {adds, dels}),
    do: count_changes(rest, {old, max(new - 1, 0)}, {adds + 1, dels})

  defp count_changes(["-" <> _ | rest], {old, new}, {adds, dels}),
    do: count_changes(rest, {max(old - 1, 0), new}, {adds, dels + 1})

  defp count_changes([" " <> _ | rest], hunk, count),
    do: count_changes(rest, context(hunk), count)

  defp count_changes(["" | rest], hunk, count), do: count_changes(rest, context(hunk), count)

  defp count_changes([_line | rest], hunk, count), do: count_changes(rest, hunk, count)

  defp context({old, new}), do: {max(old - 1, 0), max(new - 1, 0)}

  defp hunk_size(line) do
    case Regex.run(@hunk_header, line) do
      [_ | counts] -> {hunk_count(counts, 0), hunk_count(counts, 1)}
      nil -> @outside_hunk
    end
  end

  # A count left out of the header (`@@ -3 +3 @@`) means one line.
  defp hunk_count(counts, index) do
    case Enum.at(counts, index) do
      count when count in [nil, ""] -> 1
      count -> String.to_integer(count)
    end
  end

  defp truncated?(diff) do
    last_line =
      diff
      |> String.split(["\r\n", "\n"])
      |> Enum.reverse()
      |> Enum.find(&(String.trim(&1) != ""))

    last_line == Backfill.truncation_marker()
  end
end
